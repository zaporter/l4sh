-- Output storage and panel for l4sh
-- Manages output files and the right-side output panel
-- Supports streaming output for live updates via file watching

local M = {}
local terminal = require('terminal')

M.dir = nil
M.win = nil
M.buf = nil
M.current_id = nil
M.session_dir = nil

-- Streaming state: tracks partial output for each eval_id
M.streaming = {}  -- {eval_id -> {lines = {}, timer = uv_timer, last_size = number}}

-- Terminal sessions: tracks active terminals by eval_id
M.terminals = {}  -- {eval_id -> {buf = buffer, job = job_id}}

-- Keep the child PTY aligned with the visible panel, including when a hidden
-- terminal is shown again. Do not depend on terminal-mode redraw timing.
local function sync_terminal_size()
  if not M.win or not vim.api.nvim_win_is_valid(M.win) then return end
  local buf = vim.api.nvim_win_get_buf(M.win)
  for _, term in pairs(M.terminals) do
    if term.buf == buf and term.job then
      local info = vim.fn.getwininfo(M.win)[1]
      local width = math.max(1, vim.api.nvim_win_get_width(M.win) - info.textoff)
      local height = math.max(1, vim.api.nvim_win_get_height(M.win))
      if term.width ~= width or term.height ~= height then
        vim.fn.jobresize(term.job, width, height)
        term.width, term.height = width, height
      end
      return
    end
  end
end

vim.api.nvim_create_autocmd({ 'WinResized', 'VimResized', 'BufWinEnter' }, {
  group = vim.api.nvim_create_augroup('L4shTerminalSize', { clear = true }),
  callback = function() vim.schedule(sync_terminal_size) end,
})

function M.init(output_dir, session_dir)
  M.dir = output_dir
  M.session_dir = session_dir
  if M.dir then
    vim.fn.mkdir(M.dir, "p")
  end
end

-- File operations

function M.save(id, lines)
  if not M.dir then return end
  local f = io.open(M.dir .. "/" .. id .. ".txt", "w")
  if f then
    f:write(table.concat(lines, "\n"))
    f:close()
  end
end

function M.load(id)
  if not M.dir then return nil end
  local f = io.open(M.dir .. "/" .. id .. ".txt", "r")
  if f then
    local content = f:read("*a")
    f:close()
    return vim.split(content, "\n")
  end
  return nil
end

function M.delete(id)
  if not M.dir then return end
  os.remove(M.dir .. "/" .. id .. ".txt")
end

-- Panel operations

local function find_tree_window()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    local ft = vim.api.nvim_get_option_value('filetype', { buf = buf })
    if ft == 'NvimTree' then
      return win, vim.api.nvim_win_get_width(win)
    end
  end
  return nil, nil
end

local function ensure_buffer()
  if not M.buf or not vim.api.nvim_buf_is_valid(M.buf) then
    M.buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_option_value('bufhidden', 'hide', { buf = M.buf })
    vim.api.nvim_set_option_value('filetype', 'lean', { buf = M.buf })
    vim.api.nvim_buf_set_name(M.buf, '[l4sh output]')
  end
  return M.buf
end

local function ensure_window()
  if not M.win or not vim.api.nvim_win_is_valid(M.win) then
    local tree_win, tree_width = find_tree_window()
    local cur_win = vim.api.nvim_get_current_win()

    vim.cmd('botright vsplit')
    M.win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(M.win, ensure_buffer())

    vim.api.nvim_set_option_value('number', false, { win = M.win })
    vim.api.nvim_set_option_value('relativenumber', false, { win = M.win })
    vim.api.nvim_set_option_value('signcolumn', 'no', { win = M.win })

    -- Restore nvim-tree width
    if tree_win and tree_width and vim.api.nvim_win_is_valid(tree_win) then
      vim.api.nvim_win_set_width(tree_win, tree_width)
    end

    vim.api.nvim_set_current_win(cur_win)
  end
  return M.win
end

function M.show(lines, id)
  ensure_buffer()

  -- Update content
  vim.api.nvim_set_option_value('modifiable', true, { buf = M.buf })
  vim.api.nvim_buf_set_lines(M.buf, 0, -1, false, lines)
  vim.api.nvim_set_option_value('modifiable', false, { buf = M.buf })

  ensure_window()
  -- Make sure window shows the static buffer (might be showing a terminal)
  vim.api.nvim_win_set_buf(M.win, M.buf)
  M.current_id = id
end

-- Streaming support via file watching

local function get_stream_file()
  if M.session_dir then
    return M.session_dir .. "/stream.txt"
  end
  return nil
end

local function read_stream_file()
  local path = get_stream_file()
  if not path then return nil end
  local f = io.open(path, "r")
  if not f then return nil end
  local content = f:read("*a")
  f:close()
  return content
end

local function update_stream_display(id)
  local stream = M.streaming[id]
  if not stream then return end

  if M.current_id == id and M.buf and vim.api.nvim_buf_is_valid(M.buf) then
    vim.api.nvim_set_option_value('modifiable', true, { buf = M.buf })
    vim.api.nvim_buf_set_lines(M.buf, 0, -1, false, stream.lines)
    vim.api.nvim_set_option_value('modifiable', false, { buf = M.buf })
  end
end

function M.stream_start(id)
  -- Stop any existing stream for this id
  if M.streaming[id] and M.streaming[id].timer then
    M.streaming[id].timer:stop()
    M.streaming[id].timer:close()
  end

  M.streaming[id] = {
    lines = { '-- executing... --' },
    last_content = "",
    timer = nil,
  }

  -- Always show immediately when a command starts executing
  M.show(M.streaming[id].lines, id)

  -- Start polling the stream file
  local timer = vim.uv.new_timer()
  M.streaming[id].timer = timer

  timer:start(100, 100, vim.schedule_wrap(function()
    local stream = M.streaming[id]
    if not stream then
      timer:stop()
      timer:close()
      return
    end

    local content = read_stream_file()
    if content and content ~= stream.last_content and content ~= "" then
      stream.last_content = content
      stream.lines = vim.split(content, "\n", { trimempty = true })
      if #stream.lines == 0 then
        stream.lines = { '-- executing... --' }
      end
      update_stream_display(id)
    end
  end))
end

function M.stream_append(id, line)
  -- Not used with file-based streaming, kept for compatibility
  local stream = M.streaming[id]
  if not stream then return end
end

function M.stream_finish(id, final_lines)
  local stream = M.streaming[id]
  if stream and stream.timer then
    stream.timer:stop()
    stream.timer:close()
  end
  M.streaming[id] = nil

  -- Save and show final output
  M.save(id, final_lines)
  if M.current_id == id then
    M.show(final_lines, id)
  end
end

function M.stream_get(id)
  local stream = M.streaming[id]
  return stream and stream.lines or nil
end

function M.is_streaming(id)
  return M.streaming[id] ~= nil
end

-- Get the latest (highest) eval ID with output
function M.get_latest_id()
  local max_id = nil

  -- Check terminals
  for id, _ in pairs(M.terminals) do
    local num = tonumber(id)
    if num and (not max_id or num > max_id) then
      max_id = num
    end
  end

  -- Check streaming outputs
  for id, _ in pairs(M.streaming) do
    local num = tonumber(id)
    if num and (not max_id or num > max_id) then
      max_id = num
    end
  end

  -- Check saved output files
  if M.dir then
    local handle = vim.uv.fs_scandir(M.dir)
    if handle then
      while true do
        local name, type = vim.uv.fs_scandir_next(handle)
        if not name then break end
        if type == "file" and name:match("^%d+%.txt$") then
          local num = tonumber(name:match("^(%d+)%.txt$"))
          if num and (not max_id or num > max_id) then
            max_id = num
          end
        end
      end
    end
  end

  return max_id and tostring(max_id) or nil
end

function M.hide()
  if M.win and vim.api.nvim_win_is_valid(M.win) then
    vim.api.nvim_win_close(M.win, true)
    M.win = nil
  end
  M.current_id = nil
end

function M.is_visible()
  return M.win and vim.api.nvim_win_is_valid(M.win)
end

-- Terminal support for interactive shell commands

-- Check if an eval_id has an active terminal
function M.has_terminal(id)
  local term = M.terminals[id]
  return term and term.buf and vim.api.nvim_buf_is_valid(term.buf) and term.job
end

-- Open an interactive shell command in the output panel for a specific eval_id
function M.run_shell(cmd, cwd, id, on_exit)
  local id_str = tostring(id)
  local tree_win, tree_width = find_tree_window()

  -- Create a fresh terminal buffer and keep it when the panel is hidden.
  local term_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[term_buf].bufhidden = 'hide'
  vim.api.nvim_buf_set_name(term_buf, '[l4sh terminal #' .. id_str .. ']')

  -- Create/ensure window
  if not M.win or not vim.api.nvim_win_is_valid(M.win) then
    vim.cmd('botright vsplit')
    M.win = vim.api.nvim_get_current_win()
    vim.api.nvim_set_option_value('number', false, { win = M.win })
    vim.api.nvim_set_option_value('relativenumber', false, { win = M.win })
    vim.api.nvim_set_option_value('signcolumn', 'no', { win = M.win })

    -- Restore nvim-tree width
    if tree_win and tree_width and vim.api.nvim_win_is_valid(tree_win) then
      vim.api.nvim_win_set_width(tree_win, tree_width)
    end
  end

  -- Set terminal buffer in window
  vim.api.nvim_win_set_buf(M.win, term_buf)

  -- Focus the terminal window and start the job
  vim.api.nvim_set_current_win(M.win)

  -- Keep a native PTY for the child and feed its bytes into Neovim's renderer.
  -- This lets us translate unsupported ANSI cursor save/restore codes before
  -- libvterm sees them. Input and terminal-query replies go straight to the PTY.
  local filter = terminal.new_filter()
  local job
  local channel = vim.api.nvim_open_term(term_buf, {
    force_crlf = false,
    on_input = function(_, _, _, data)
      if job then vim.fn.chansend(job, data) end
    end,
  })
  -- Unlike a terminal created by jobstart(term=true), the renderer does not
  -- own this job. Stop the child if the user wipes its buffer directly.
  vim.api.nvim_create_autocmd('BufWipeout', {
    buffer = term_buf,
    once = true,
    callback = function()
      if job then
        vim.fn.jobstop(job)
        job = nil
      end
      local term = M.terminals[id_str]
      if term and term.buf == term_buf then M.terminals[id_str] = nil end
    end,
  })
  local function render(data)
    if vim.api.nvim_buf_is_valid(term_buf) then
      vim.api.nvim_chan_send(channel, data)
    end
  end
  local info = vim.fn.getwininfo(M.win)[1]
  local ok, term_job = pcall(vim.fn.jobstart, { '/bin/sh', '-c', cmd }, {
    pty = true,
    width = math.max(1, vim.api.nvim_win_get_width(M.win) - info.textoff),
    height = math.max(1, vim.api.nvim_win_get_height(M.win)),
    env = { TERM = 'xterm-256color' },
    cwd = cwd,
    on_stdout = function(_, data)
      render(filter.feed(table.concat(data, '\n')))
    end,
    on_exit = function(job_id, exit_code, event)
      job = nil
      render(filter.finish())
      render('\r\n[Process exited ' .. exit_code .. ']\r\n')
      vim.schedule(function()
        -- Clean up terminal tracking
        local term = M.terminals[id_str]
        if term and term.job == job_id then
          term.job = nil
          -- Keep buffer around for scrollback viewing
        end
        if on_exit then
          on_exit(exit_code)
        end
      end)
    end,
  })

  if not ok or term_job <= 0 then
    local message = 'Failed to start terminal: ' .. tostring(term_job)
    M.show({ message }, id_str)
    vim.api.nvim_buf_delete(term_buf, { force = true })
    if on_exit then on_exit(127) end
    vim.notify(message, vim.log.levels.ERROR)
    return
  end
  job = term_job

  -- Track this terminal by eval_id
  M.terminals[id_str] = {
    buf = term_buf,
    job = term_job,
  }
  sync_terminal_size()

  -- Enter insert mode for immediate interaction
  vim.cmd('startinsert')

  M.current_id = id_str
end

-- Unified show function: displays the right content for an eval_id
-- Handles: active terminals, streaming output, saved output
function M.show_for_id(id)
  local id_str = tostring(id)

  -- Already showing this id?
  if id_str == M.current_id then return end

  ensure_window()

  -- Check for active/finished terminal
  local term = M.terminals[id_str]
  if term and term.buf and vim.api.nvim_buf_is_valid(term.buf) then
    vim.api.nvim_win_set_buf(M.win, term.buf)
    sync_terminal_size()
    M.current_id = id_str
    return
  end

  -- Check for streaming output
  local stream = M.streaming[id_str]
  if stream then
    M.show(stream.lines, id_str)
    return
  end

  -- Check for saved output
  local lines = M.load(id_str)
  if lines then
    M.show(lines, id_str)
    return
  end

  -- No output found
  M.show({ '(no output)' }, id_str)
end

-- Close a specific terminal
function M.close_terminal(id)
  local id_str = tostring(id)
  local term = M.terminals[id_str]
  if not term then return end

  if term.job then
    vim.fn.jobstop(term.job)
  end
  if term.buf and vim.api.nvim_buf_is_valid(term.buf) then
    vim.api.nvim_buf_delete(term.buf, { force = true })
  end
  M.terminals[id_str] = nil

  -- Switch window back to regular output buffer if this was visible
  if M.current_id == id_str and M.win and vim.api.nvim_win_is_valid(M.win) then
    vim.api.nvim_win_set_buf(M.win, ensure_buffer())
    M.current_id = nil
  end
end

-- Close all terminals
function M.close_all_terminals()
  for id, _ in pairs(M.terminals) do
    M.close_terminal(id)
  end
end

-- Check if current output is a terminal
function M.is_terminal()
  if not M.current_id then return false end
  return M.has_terminal(M.current_id)
end

return M
