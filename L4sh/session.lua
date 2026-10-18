-- Session management for l4sh
-- Handles session browsing, creation, and initialization

local M = {}

M.sessions_dir = os.getenv("HOME") .. "/.l4sh/sessions"
M.project_root = nil

--------------------------------------------------------------------------------
-- Session utilities
--------------------------------------------------------------------------------

-- Get all session directories sorted by modification time (newest first)
function M.list_sessions()
  local sessions = {}
  local handle = vim.uv.fs_scandir(M.sessions_dir)
  if not handle then return sessions end

  while true do
    local name, type = vim.uv.fs_scandir_next(handle)
    if not name then break end
    if type == "directory" then
      local shell_path = M.sessions_dir .. "/" .. name .. "/Shell.lean"
      local stat = vim.uv.fs_stat(shell_path)
      if stat then
        table.insert(sessions, {
          name = name,
          path = M.sessions_dir .. "/" .. name,
          shell_file = shell_path,
          mtime = stat.mtime.sec,
        })
      end
    end
  end

  -- Sort by modification time, newest first
  table.sort(sessions, function(a, b)
    return a.mtime > b.mtime
  end)

  return sessions
end

-- Create a new session directory
-- If name is nil, use timestamp-based naming
function M.create_session(name)
  local session_name
  if name and name ~= "" then
    session_name = name
  else
    session_name = os.date("%Y-%m-%d_%H-%M-%S")
  end

  local session_dir = M.sessions_dir .. "/" .. session_name
  local output_dir = session_dir .. "/output"

  -- Create directories
  vim.fn.mkdir(output_dir, "p")

  -- Get initial working directory
  local initial_cwd = M.project_root or vim.fn.getcwd()

  -- Create state file
  local state_file = session_dir .. "/state.json"
  local f = io.open(state_file, "w")
  if f then
    f:write(vim.json.encode({
      version = 1,
      cwd = initial_cwd,
      files = {},
      git = vim.NIL,
    }))
    f:close()
  end

  -- Create Shell.lean file
  local shell_file = session_dir .. "/Shell.lean"
  f = io.open(shell_file, "w")
  if f then
    f:write("import L4sh.Shell\n-- Uncomment to load each project's .envrc for shell commands:\n-- direnv on\n\n$: ")
    f:close()
  end

  return {
    name = session_name,
    path = session_dir,
    shell_file = shell_file,
    state_file = state_file,
    output_dir = output_dir,
  }
end

--------------------------------------------------------------------------------
-- Session initialization (set up env and modules for a session)
--------------------------------------------------------------------------------

function M.init_session(session)
  -- Set environment variables
  local state_file = session.state_file or (session.path .. "/state.json")
  vim.env.LEAN_SHELL_STATE = state_file
  vim.env.L4SH_SESSION_DIR = session.path

  -- Set global variables for other modules
  vim.g.l4sh_session_dir = session.path
  vim.g.l4sh_project_root = M.project_root

  -- Initialize l4sh modules
  local eval = require('eval')
  local output = require('output')
  local state_mod = require('state')
  local repl = require('repl')

  eval.init(session.path)
  output.init(session.path .. "/output", session.path)
  state_mod.state_file = state_file

  -- Set REPL session env (restarts workers to pick up new state file)
  repl.set_session_env({
    LEAN_SHELL_STATE = state_file,
    L4SH_SESSION_DIR = session.path,
  })

  -- Update global l4sh module state if it exists
  if _G.l4sh then
    _G.l4sh.session_dir = session.path
    _G.l4sh.is_l4sh_session = true
    _G.l4sh.session_loaded = false
    _G.l4sh.loaded_file = nil
  end
end

--------------------------------------------------------------------------------
-- Telescope picker for sessions
--------------------------------------------------------------------------------

function M.pick_session(callback)
  local ok, telescope = pcall(require, 'telescope.builtin')
  if not ok then
    vim.notify("telescope.nvim is required for session picker", vim.log.levels.ERROR)
    return
  end

  local pickers = require('telescope.pickers')
  local finders = require('telescope.finders')
  local conf = require('telescope.config').values
  local actions = require('telescope.actions')
  local action_state = require('telescope.actions.state')
  local previewers = require('telescope.previewers')

  local sessions = M.list_sessions()

  if #sessions == 0 then
    vim.notify("No existing sessions found. Creating new session...", vim.log.levels.INFO)
    local session = M.create_session(nil)
    callback(session)
    return
  end

  pickers.new({}, {
    prompt_title = "l4sh Sessions  |  <C-n> new  <C-a> named  <C-d> delete",
    finder = finders.new_table({
      results = sessions,
      entry_maker = function(entry)
        return {
          value = entry,
          display = entry.name,
          ordinal = entry.name,
          path = entry.shell_file,
        }
      end,
    }),
    sorter = conf.generic_sorter({}),
    previewer = previewers.new_buffer_previewer({
      title = "Shell.lean Preview",
      define_preview = function(self, entry, status)
        local lines = vim.fn.readfile(entry.path)
        vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)
        vim.api.nvim_set_option_value('filetype', 'lean', { buf = self.state.bufnr })
      end,
    }),
    attach_mappings = function(prompt_bufnr, map)
      -- Enter: open selected session
      actions.select_default:replace(function()
        actions.close(prompt_bufnr)
        local selection = action_state.get_selected_entry()
        if selection then
          callback(selection.value)
        end
      end)

      -- <C-n>: create new unnamed session
      map('i', '<C-n>', function()
        actions.close(prompt_bufnr)
        local session = M.create_session(nil)
        vim.notify("Created new session: " .. session.name, vim.log.levels.INFO)
        callback(session)
      end)

      -- <C-N> (shift): create new named session
      map('i', '<C-S-n>', function()
        actions.close(prompt_bufnr)
        vim.ui.input({ prompt = "Session name: " }, function(name)
          if name and name ~= "" then
            local session = M.create_session(name)
            vim.notify("Created new session: " .. session.name, vim.log.levels.INFO)
            callback(session)
          end
        end)
      end)

      -- <C-a>: create named session (alternative binding for 'add')
      map('i', '<C-a>', function()
        actions.close(prompt_bufnr)
        vim.ui.input({ prompt = "Session name: " }, function(name)
          if name and name ~= "" then
            local session = M.create_session(name)
            vim.notify("Created new session: " .. session.name, vim.log.levels.INFO)
            callback(session)
          end
        end)
      end)

      -- Also bind in normal mode
      map('n', '<C-n>', function()
        actions.close(prompt_bufnr)
        local session = M.create_session(nil)
        vim.notify("Created new session: " .. session.name, vim.log.levels.INFO)
        callback(session)
      end)

      map('n', '<C-a>', function()
        actions.close(prompt_bufnr)
        vim.ui.input({ prompt = "Session name: " }, function(name)
          if name and name ~= "" then
            local session = M.create_session(name)
            vim.notify("Created new session: " .. session.name, vim.log.levels.INFO)
            callback(session)
          end
        end)
      end)

      -- <C-d>: delete session with confirmation
      local function delete_session()
        local selection = action_state.get_selected_entry()
        if not selection then return end

        local session_name = selection.value.name
        local session_path = selection.value.path

        vim.ui.input({
          prompt = "Delete session '" .. session_name .. "'? Type 'yes' to confirm: "
        }, function(input)
          if input == "yes" then
            -- Delete the session directory recursively
            vim.fn.delete(session_path, "rf")
            vim.notify("Deleted session: " .. session_name, vim.log.levels.INFO)

            -- Refresh the picker
            local current_picker = action_state.get_current_picker(prompt_bufnr)
            local new_sessions = M.list_sessions()

            if #new_sessions == 0 then
              actions.close(prompt_bufnr)
              vim.notify("No sessions remaining. Creating new session...", vim.log.levels.INFO)
              local session = M.create_session(nil)
              callback(session)
            else
              current_picker:refresh(finders.new_table({
                results = new_sessions,
                entry_maker = function(entry)
                  return {
                    value = entry,
                    display = entry.name,
                    ordinal = entry.name,
                    path = entry.shell_file,
                  }
                end,
              }), { reset_prompt = false })
            end
          else
            vim.notify("Delete cancelled", vim.log.levels.INFO)
          end
        end)
      end

      map('i', '<C-d>', delete_session)
      map('n', '<C-d>', delete_session)

      return true
    end,
  }):find()
end

--------------------------------------------------------------------------------
-- Main entry point: called from nvim -c
--------------------------------------------------------------------------------

-- Clean up current session before switching
local function cleanup_current_session()
  -- Stop REPL workers
  local ok, repl = pcall(require, 'repl')
  if ok and repl.stop then
    repl.stop()
  end

  -- Stop state polling and hide status
  local ok2, state_mod = pcall(require, 'state')
  if ok2 then
    if state_mod.stop_polling then state_mod.stop_polling() end
    if state_mod.hide_status then state_mod.hide_status() end
  end

  -- Close output panel
  local ok3, output = pcall(require, 'output')
  if ok3 then
    if output.close_all_terminals then output.close_all_terminals() end
    if output.hide then output.hide() end
  end

  -- Reset .nvim.lua session state (via global reference)
  if _G.l4sh and _G.l4sh.reset_session_state then
    _G.l4sh.reset_session_state()
  end

  -- Clear the session dir global
  vim.g.l4sh_session_dir = nil
end

local function open_session_ui(session)
  M.init_session(session)

  -- Open the Shell.lean file
  vim.cmd('edit ' .. vim.fn.fnameescape(session.shell_file))

  -- Remember the shell window for later width setting
  local shell_win = vim.api.nvim_get_current_win()

  -- Initialize UI, REPL, and tabs
  local ui = require('ui')
  local repl = require('repl')
  local state = require('state')
  local tabs = require('tabs')

  -- Mark this tab as the l4sh tab
  tabs.mark_as_l4sh_tab()

  ui.setup()
  repl.start(M.project_root)
  state.show_status()
  state.start_polling()

  -- Open nvim-tree on the left, synced to session's cwd
  -- Read session state to get cwd
  local session_cwd = nil
  local state_file = session.state_file or (session.path .. "/state.json")
  local f = io.open(state_file, "r")
  if f then
    local content = f:read("*a")
    f:close()
    local ok2, state_data = pcall(vim.json.decode, content)
    if ok2 and state_data and state_data.cwd and state_data.cwd ~= vim.NIL then
      session_cwd = state_data.cwd
    end
  end

  local tree_path = session_cwd or M.project_root or vim.fn.getcwd()

  -- Change neovim's working directory (affects telescope, etc.)
  vim.cmd('cd ' .. vim.fn.fnameescape(tree_path))

  -- Use state module's robust sync helper
  state.sync_nvim_tree(tree_path, { force = true, open_if_closed = true })

  -- Return focus to the shell file
  vim.cmd('wincmd l')

  -- Open output panel on the right (it will take remaining space)
  local output = require('output')
  output.show({ '-- ready --' }, '0')

  -- Now set Shell.lean window to fixed 60 chars wide
  -- This must happen AFTER output panel opens so it takes remaining space
  vim.defer_fn(function()
    if vim.api.nvim_win_is_valid(shell_win) then
      vim.api.nvim_set_current_win(shell_win)
      vim.api.nvim_win_set_width(shell_win, 60)
      vim.api.nvim_set_option_value('winfixwidth', true, { win = shell_win })
      -- Move cursor to end and enter insert mode
      vim.cmd('normal! G$')
      vim.cmd('startinsert!')
    end
  end, 50)
end

function M.start()
  -- Ensure sessions directory exists
  vim.fn.mkdir(M.sessions_dir, "p")

  -- Defer picker slightly to let nvim fully settle on startup
  vim.defer_fn(function()
    M.pick_session(function(session)
      open_session_ui(session)
    end)
  end, 50)
end

-- Switch to a different session (cleanup current, show picker)
function M.switch()
  cleanup_current_session()
  M.pick_session(function(session)
    open_session_ui(session)
  end)
end

--------------------------------------------------------------------------------
-- Direct session start (for when user wants to skip picker)
--------------------------------------------------------------------------------

-- Start a new unnamed session immediately
function M.new_unnamed()
  local session = M.create_session(nil)
  vim.notify("Created new session: " .. session.name, vim.log.levels.INFO)
  open_session_ui(session)
end

-- Start a new named session immediately
function M.new_named(name)
  if not name or name == "" then
    vim.ui.input({ prompt = "Session name: " }, function(input)
      if input and input ~= "" then
        M.new_named(input)
      end
    end)
    return
  end

  local session = M.create_session(name)
  vim.notify("Created new session: " .. session.name, vim.log.levels.INFO)
  open_session_ui(session)
end

return M
