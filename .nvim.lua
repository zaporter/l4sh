-- l4sh: Lean 4 Shell - Project-local Neovim configuration
-- Provides $: shell command execution for Lean files via persistent REPL

local M = {}

vim.opt.splitbelow = true

-- Session config
M.session_dir = vim.g.l4sh_session_dir
M.project_root = vim.g.l4sh_project_root or vim.fs.root(0, {'lakefile.lean', 'lakefile.toml'}) or vim.fn.getcwd()
M.is_l4sh_session = M.session_dir ~= nil

-- Override Lean LSP root_dir for Shell.lean files in sessions
-- This ensures imports resolve against the l4sh project even when cwd is elsewhere
local l4sh_sessions_pattern = vim.pesc(os.getenv('HOME')) .. '/%.l4sh/sessions/'
vim.lsp.config('leanls', {
  root_dir = function(bufnr, on_dir)
    local fname = vim.api.nvim_buf_get_name(bufnr)
    fname = vim.fs.normalize(fname)

    -- If this is a Shell.lean in l4sh sessions, use the l4sh project as root
    if fname:match(l4sh_sessions_pattern) then
      on_dir(M.project_root)
      return
    end

    -- Default lean.nvim behavior: find lakefile or lean-toolchain
    on_dir(vim.fs.root(fname, { 'lakefile.toml', 'lakefile.lean', 'lean-toolchain' }))
  end,
})

-- Load modules
package.path = package.path .. ";" .. M.project_root .. "/L4sh/?.lua"
local repl = require('repl')
local eval = require('eval')
local output = require('output')
local ui = require('ui')
local state = require('state')
local tabs = require('tabs')

-- Initialize modules
eval.init(M.session_dir)
output.init(M.session_dir and (M.session_dir .. "/output") or nil, M.session_dir)
ui.setup()

if M.is_l4sh_session then
  state.state_file = M.session_dir .. "/state.json"
end

-- Session state
M.loaded_file = nil
M.session_loaded = false

-- Reset session state (called when switching sessions)
function M.reset_session_state()
  M.loaded_file = nil
  M.session_loaded = false
  M.session_dir = nil
end

-- Convert file path to Lean module name
local function file_to_module(filepath)
  local root = vim.fs.root(0, {'lakefile.lean', 'lakefile.toml', 'lean-toolchain'}) or vim.fn.getcwd()
  local rel = filepath:sub(#root + 2)
  return rel:gsub('%.lean$', ''):gsub('/', '.')
end


-- Process REPL response into output lines
-- Returns: lines, has_error, terminal_request (if shi was used)
local function process_response(resp)
  local lines = {}
  local has_error = false
  local terminal_request = nil

  if resp.messages then
    for _, msg in ipairs(resp.messages) do
      if msg.severity == 'error' then has_error = true end
      for line in (msg.data or ''):gmatch('[^\n]+') do
        -- Decode the request as JSON to preserve quotes/newlines in commands.
        local ok, decoded = pcall(vim.json.decode, line)
        local request = ok and type(decoded) == 'table' and decoded.__l4sh_terminal__
        if type(request) == 'table' and type(request.cmd) == 'string'
            and type(request.cwd) == 'string' then
          terminal_request = request
        else
          table.insert(lines, line)
        end
      end
    end
  end

  if resp.sorries then
    for _, sorry in ipairs(resp.sorries) do
      table.insert(lines, 'sorry: ' .. (sorry.goal or ''))
      has_error = true
    end
  end

  if #lines == 0 and not terminal_request then
    table.insert(lines, '(no output)')
  end

  return lines, has_error, terminal_request
end

-- Execute a $: block and handle result
local function execute_block(code, eval_id, bufnr)
  local id_str = tostring(eval_id)
  local t0 = vim.uv.hrtime()

  -- Start streaming output
  output.stream_start(id_str)

  local combined = '#eval_line 2\n' .. code

  -- Streaming callback for partial output
  local function on_output(line)
    output.stream_append(id_str, line)
  end

  -- Completion callback
  local function on_complete(resp)
    local duration_ms = (vim.uv.hrtime() - t0) / 1e6

    local lines, has_error, terminal_request = process_response(resp)
    local status = has_error and 'err' or 'ok'

    -- Launch directly in Neovim's PTY; socket bridges lose terminal resizes.
    if terminal_request and not has_error then
      output.stream_finish(id_str, lines)

      output.run_shell(terminal_request.cmd, terminal_request.cwd, eval_id, function(exit_code)
        local final_duration = (vim.uv.hrtime() - t0) / 1e6
        local final_status = exit_code == 0 and 'ok' or 'err'

        output.save(id_str, { 'Terminal session ended', 'Exit code: ' .. exit_code })

        if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
          local filename = vim.api.nvim_buf_get_name(bufnr)
          if eval.is_session_file(filename) then
            eval.update_status(bufnr, eval_id, final_status, final_duration)
            ui.update_markers(bufnr)
            -- Write the specific buffer, not current buffer
            vim.api.nvim_buf_call(bufnr, function()
              vim.cmd('silent write')
            end)
          end
        end

        state.refresh()
      end)
      return
    end

    -- Finish streaming with final output
    output.stream_finish(id_str, lines)

    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
      local filename = vim.api.nvim_buf_get_name(bufnr)
      if eval.is_session_file(filename) then
        eval.update_status(bufnr, eval_id, status, duration_ms)
        ui.update_markers(bufnr)
        -- Write the specific buffer, not current buffer
        vim.api.nvim_buf_call(bufnr, function()
          vim.cmd('silent write')
        end)
      end
    end

    state.refresh()
  end

  repl.send(combined, on_complete, nil, on_output, eval_id)
end

-- Load session file content into all workers
local function load_session_file(filename, callback)
  vim.notify('Loading session...', vim.log.levels.INFO)
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local content = table.concat(lines, '\n')

  repl.load_session(content, function(resp)
    M.session_loaded = true
    vim.notify('Session ready', vim.log.levels.INFO)
    if callback then callback(resp) end
  end)
end

-- Import a module into all workers
local function import_module(module, callback)
  vim.notify('Importing ' .. module .. '...', vim.log.levels.INFO)
  repl.import_module(module, function(resp)
    M.loaded_file = module
    vim.notify('Ready', vim.log.levels.INFO)
    if callback then callback(resp) end
  end)
end

-- Main shell command: execute $: block under cursor
function M.shell()
  local bufnr = vim.api.nvim_get_current_buf()
  local filename = vim.api.nvim_buf_get_name(bufnr)

  if not filename:match('%.lean$') then
    vim.notify('Not a Lean file', vim.log.levels.WARN)
    return
  end

  local code, cmd_line, _, existing_id, marker_line = eval.get_shell_block()
  if not code then
    vim.notify('No $: command found at or before cursor', vim.log.levels.WARN)
    return
  end

  -- Auto-save session files before execution
  if eval.is_session_file(filename) and vim.bo[bufnr].modified then
    vim.api.nvim_buf_call(bufnr, function()
      vim.cmd('silent write')
    end)
  end

  if not repl.is_running() then
    repl.start(M.project_root)
    vim.defer_fn(function() M.shell() end, 500)
    return
  end

  local eval_id = eval.next_id()

  if eval.is_session_file(filename) then
    if existing_id then output.delete(tostring(existing_id)) end
    eval.set_marker(bufnr, cmd_line, existing_id, marker_line, eval_id, 'pending')
    vim.schedule(function() ui.update_markers(bufnr) end)
  end

  if eval.is_session_file(filename) then
    if not M.session_loaded then
      load_session_file(filename, function()
        execute_block(code, eval_id, bufnr)
      end)
      return
    end
    execute_block(code, eval_id, bufnr)
    return
  end

  local module = file_to_module(filename)
  if M.loaded_file ~= module then
    import_module(module, function()
      execute_block(code, eval_id, bufnr)
    end)
    return
  end

  execute_block(code, eval_id, bufnr)
end

-- Reload current file (restarts worker pool and re-initializes)
function M.reload()
  local filename = vim.api.nvim_buf_get_name(0)
  if not filename:match('%.lean$') then
    vim.notify('Not a Lean file', vim.log.levels.WARN)
    return
  end

  if eval.is_session_file(filename) then
    M.session_loaded = false
    -- Restart pool and reload session
    repl.restart(M.project_root)
    vim.defer_fn(function()
      load_session_file(filename)
    end, 100)
    return
  end

  local module = file_to_module(filename)

  vim.notify('Building ' .. module .. '...', vim.log.levels.INFO)
  vim.fn.jobstart({'lake', 'build', module}, {
    cwd = M.project_root,
    on_exit = function(_, code, _)
      vim.schedule(function()
        if code == 0 then
          M.loaded_file = nil
          -- Restart pool and re-import module
          repl.restart(M.project_root)
          vim.defer_fn(function()
            import_module(module)
          end, 100)
        else
          vim.notify('Build failed', vim.log.levels.ERROR)
        end
      end)
    end,
  })
end

-- Check cursor and update output panel
local function check_cursor_for_output()
  local bufnr = vim.api.nvim_get_current_buf()
  local filename = vim.api.nvim_buf_get_name(bufnr)

  if not eval.is_session_file(filename) then return end

  local id = eval.get_block_at_cursor()
  if id then
    output.show_for_id(id)
  else
    -- No block at cursor (e.g., new empty $: line) - show most recent output
    local latest_id = output.get_latest_id()
    if latest_id then
      output.show_for_id(latest_id)
    end
  end
end

-- Autocmds

-- Set up nvim-tree keymaps to use our tab system
vim.api.nvim_create_autocmd('FileType', {
  pattern = 'NvimTree',
  callback = function(args)
    tabs.setup_nvim_tree_keymaps(args.buf)
  end,
})

vim.api.nvim_create_autocmd({'BufEnter', 'BufWinEnter'}, {
  pattern = '*.lean',
  callback = function()
    local filename = vim.api.nvim_buf_get_name(0)
    if eval.is_session_file(filename) then
      ui.update_markers()
    end
  end,
})

vim.api.nvim_create_autocmd({'TextChanged', 'TextChangedI'}, {
  pattern = '*.lean',
  callback = function()
    local filename = vim.api.nvim_buf_get_name(0)
    if eval.is_session_file(filename) then
      vim.defer_fn(function() ui.update_markers() end, 10)
    end
  end,
})

vim.api.nvim_create_autocmd({'CursorMoved', 'CursorMovedI'}, {
  pattern = '*.lean',
  callback = function()
    vim.defer_fn(check_cursor_for_output, 50)
  end,
})

-- Commands
vim.api.nvim_create_user_command('LeanShell', function() M.shell() end, {})
vim.api.nvim_create_user_command('LeanReplStart', function() repl.start(M.project_root) end, {})
vim.api.nvim_create_user_command('LeanReplStop', function() repl.stop() end, {})
vim.api.nvim_create_user_command('LeanReplRestart', function() repl.restart(M.project_root) end, {})
vim.api.nvim_create_user_command('LeanReplStatus', function()
  local s = repl.status()
  print(string.format('workers:%d ready:%d busy:%d init:%d queued:%d max:%d',
    s.workers, s.ready, s.busy, s.initializing, s.queued, s.max))
end, {})
vim.api.nvim_create_user_command('LeanReload', function() M.reload() end, {})
vim.api.nvim_create_user_command('LeanOutputToggle', function()
  if output.is_visible() then
    output.hide()
  else
    check_cursor_for_output()
  end
end, {})
vim.api.nvim_create_user_command('LeanTermClose', function()
  if output.current_id then
    output.close_terminal(output.current_id)
  end
end, {})
vim.api.nvim_create_user_command('LeanTermCloseAll', function()
  output.close_all_terminals()
end, {})

-- Keymaps
vim.keymap.set('n', '<leader>le', M.shell, { desc = 'Execute $: under cursor' })
vim.keymap.set('n', '<leader>lr', M.reload, { desc = 'Reload definitions' })
vim.keymap.set('n', '<leader>ls', ':L4shSessions<CR>', { desc = 'l4sh: session picker/switch', silent = true })
vim.keymap.set('n', '<leader>lo', function()
  if output.is_visible() then output.hide() else check_cursor_for_output() end
end, { desc = 'Toggle output panel' })
vim.keymap.set('n', '<leader>lt', function()
  if output.is_visible() and output.is_terminal() then
    -- Focus the terminal window
    vim.api.nvim_set_current_win(output.win)
    vim.cmd('startinsert')
  else
    vim.notify('No active terminal', vim.log.levels.INFO)
  end
end, { desc = 'Focus terminal' })
-- In terminal mode, Escape goes to normal mode then back to editor
vim.keymap.set('t', '<Esc><Esc>', '<C-\\><C-n><C-w>p', { desc = 'Exit terminal to editor' })
-- Jump back to l4sh tab (Shell.lean view)
vim.keymap.set('n', '<leader>ll', function()
  if not tabs.goto_l4sh_tab() then
    vim.notify('No active l4sh session', vim.log.levels.WARN)
  end
end, { desc = 'Jump to l4sh tab' })

-- Telescope keymaps that use our tab system (files open in edit tab)
vim.keymap.set('n', '<leader>ff', tabs.find_files, { desc = 'Find files (edit tab)' })
vim.keymap.set('n', '<leader>fg', tabs.live_grep, { desc = 'Live grep (edit tab)' })
vim.keymap.set('n', '<leader>fo', tabs.oldfiles, { desc = 'Recent files (edit tab)' })

-- Smart Enter: execute $: block in session files, otherwise default behavior
vim.keymap.set('n', '<CR>', function()
  local filename = vim.api.nvim_buf_get_name(0)
  if eval.is_session_file(filename) then
    local code = eval.get_shell_block()
    if code then
      -- Check if this block has an active terminal - attach instead of re-run
      local id = eval.get_block_at_cursor()
      if id and output.has_terminal(id) then
        output.show_for_id(id)
        vim.api.nvim_set_current_win(output.win)
        vim.cmd('startinsert')
        return
      end

      -- Remember if we're on the last line before running
      local cursor_line = vim.fn.line('.')
      local line_count_before = vim.api.nvim_buf_line_count(0)
      local was_at_end = cursor_line >= line_count_before

      M.shell()
      -- Add new $: line at end of buffer (if needed)
      vim.schedule(function()
        local bufnr = vim.api.nvim_get_current_buf()
        -- Skip if buffer is not modifiable (e.g., terminal)
        if not vim.api.nvim_get_option_value('modifiable', { buf = bufnr }) then
          return
        end
        local line_count = vim.api.nvim_buf_line_count(bufnr)
        local last_line = vim.api.nvim_buf_get_lines(bufnr, line_count - 1, line_count, false)[1] or ''
        -- Only add new $: if last line isn't already an empty $: prompt
        if not last_line:match('^%s*%$:%s*$') then
          vim.api.nvim_buf_set_lines(bufnr, line_count, line_count, false, {'$: '})
          -- Only move to end if we were already at the end
          if was_at_end then
            vim.cmd('normal! G$')
            vim.cmd('startinsert!')
          end
        end
      end)
      return
    end
  end
  -- Default: move to next line
  vim.cmd('normal! j')
end, { desc = 'Execute $: or move down' })

-- Startup
repl.start(M.project_root)

vim.defer_fn(function()
  state.show_status()
  state.start_polling(2000)

  if M.is_l4sh_session then
    -- Mark this tab as the l4sh tab
    tabs.mark_as_l4sh_tab()

    -- Open nvim-tree synced to session's cwd
    local st = state.read_state()
    local cwd = (st and st.cwd and st.cwd ~= vim.NIL) and st.cwd or vim.fn.getcwd()
    state.sync_nvim_tree(cwd, { force = true, open_if_closed = true })
    vim.defer_fn(function() ui.fix_tree_width() end, 100)

    -- Focus the editor and position cursor ready to type
    vim.defer_fn(function()
      -- Find and focus the session file window
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        local buf = vim.api.nvim_win_get_buf(win)
        local name = vim.api.nvim_buf_get_name(buf)
        if eval.is_session_file(name) then
          vim.api.nvim_set_current_win(win)
          -- Move to end of file, insert mode
          vim.cmd('normal! G$')
          vim.cmd('startinsert!')
          break
        end
      end
    end, 200)
  end
end, 1000)

-- Exports
M.repl = repl
M.eval = eval
M.output = output
M.ui = ui
M.state = state
M.tabs = tabs

-- Global reference for session switching
_G.l4sh = M

return M
