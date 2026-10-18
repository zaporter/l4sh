-- State management and status bar for l4sh
-- Reads state from LEAN_SHELL_STATE and displays cwd + git info

local M = {}

M.state_file = os.getenv("LEAN_SHELL_STATE") or "/tmp/lean_shell_state.json"
M.status_win = nil
M.status_buf = nil
M.poll_timer = nil
M.ns = vim.api.nvim_create_namespace("l4sh_status")
M.last_synced_cwd = nil

local function setup_highlights()
  vim.api.nvim_set_hl(0, "L4shCwd", { fg = "#89b4fa", bold = true })
  vim.api.nvim_set_hl(0, "L4shBranch", { fg = "#a6e3a1" })
  vim.api.nvim_set_hl(0, "L4shDirty", { fg = "#f9e2af", bold = true })
  vim.api.nvim_set_hl(0, "L4shSep", { fg = "#585b70" })
end

function M.read_state()
  local f = io.open(M.state_file, "r")
  if not f then return nil end
  local content = f:read("*a")
  f:close()
  local ok, state = pcall(vim.json.decode, content)
  return ok and state or nil
end

local function get_git_info(dir)
  local branch = vim.fn.systemlist("git -C " .. vim.fn.shellescape(dir) .. " branch --show-current 2>/dev/null")[1]
  if vim.v.shell_error ~= 0 or not branch or branch == "" then
    return nil
  end
  local status = vim.fn.system("git -C " .. vim.fn.shellescape(dir) .. " status --porcelain 2>/dev/null")
  return { branch = branch, dirty = status ~= "" }
end

local function render_status()
  local state = M.read_state()
  local width = vim.o.columns

  local cwd = state and state.cwd
  if cwd == vim.NIL or type(cwd) ~= "string" then cwd = nil end
  cwd = cwd or vim.fn.getcwd()

  local git = state and state.git
  if git == vim.NIL then git = nil end
  git = git or get_git_info(cwd)

  local parts = {}
  local cwd_display = cwd:gsub("^" .. os.getenv("HOME"), "~")
  table.insert(parts, { text = "  " .. cwd_display .. "  ", hl = "L4shCwd" })

  if git and type(git) == "table" and git.branch then
    table.insert(parts, { text = "│", hl = "L4shSep" })
    table.insert(parts, { text = "  " .. git.branch, hl = "L4shBranch" })
    if git.dirty then
      table.insert(parts, { text = " *", hl = "L4shDirty" })
    end
    table.insert(parts, { text = "  ", hl = "Normal" })
  end

  local line = ""
  local highlights = {}
  local col = 0
  for _, part in ipairs(parts) do
    line = line .. part.text
    table.insert(highlights, { col = col, len = #part.text, hl = part.hl })
    col = col + #part.text
  end

  local pad = width - vim.fn.strdisplaywidth(line)
  if pad > 0 then
    line = line .. string.rep(" ", pad)
  end

  return { line = line, highlights = highlights }
end

function M.show_status()
  setup_highlights()
  local rendered = render_status()
  local width = vim.o.columns

  if not M.status_buf or not vim.api.nvim_buf_is_valid(M.status_buf) then
    M.status_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_option_value('bufhidden', 'hide', { buf = M.status_buf })
  end

  vim.api.nvim_set_option_value('modifiable', true, { buf = M.status_buf })
  vim.api.nvim_buf_set_lines(M.status_buf, 0, -1, false, { rendered.line })

  vim.api.nvim_buf_clear_namespace(M.status_buf, M.ns, 0, -1)
  for _, hl in ipairs(rendered.highlights) do
    vim.api.nvim_buf_add_highlight(M.status_buf, M.ns, hl.hl, 0, hl.col, hl.col + hl.len)
  end

  vim.api.nvim_set_option_value('modifiable', false, { buf = M.status_buf })

  if not M.status_win or not vim.api.nvim_win_is_valid(M.status_win) then
    M.status_win = vim.api.nvim_open_win(M.status_buf, false, {
      relative = 'editor',
      row = vim.o.lines - 2,
      col = 0,
      width = width,
      height = 1,
      style = 'minimal',
      border = 'none',
      focusable = false,
      zindex = 50,
    })
  else
    vim.api.nvim_win_set_config(M.status_win, {
      relative = 'editor',
      row = vim.o.lines - 2,
      col = 0,
      width = width,
      height = 1,
    })
  end
end

function M.hide_status()
  if M.status_win and vim.api.nvim_win_is_valid(M.status_win) then
    vim.api.nvim_win_close(M.status_win, true)
    M.status_win = nil
  end
end

function M.toggle_status()
  if M.status_win and vim.api.nvim_win_is_valid(M.status_win) then
    M.hide_status()
  else
    M.show_status()
  end
end

function M.start_polling(interval_ms)
  interval_ms = interval_ms or 1000
  M.stop_polling()

  M.poll_timer = vim.uv.new_timer()
  M.poll_timer:start(0, interval_ms, vim.schedule_wrap(function()
    if M.status_win and vim.api.nvim_win_is_valid(M.status_win) then
      M.show_status()
    end
  end))
end

function M.stop_polling()
  if M.poll_timer then
    M.poll_timer:stop()
    M.poll_timer:close()
    M.poll_timer = nil
  end
end

-- Robust nvim-tree directory sync helper
-- Handles all edge cases: visible/hidden tree, focus preservation, width preservation
function M.sync_nvim_tree(cwd, opts)
  opts = opts or {}

  -- Skip if already synced (unless forced)
  if not opts.force and cwd == M.last_synced_cwd then return end

  -- Validate cwd
  if not cwd or cwd == "" or cwd == vim.NIL then return end

  local ok, api = pcall(require, "nvim-tree.api")
  if not ok then return end

  -- Save current window to restore focus
  local cur_win = vim.api.nvim_get_current_win()

  -- Find tree window and save its width
  local tree_win, tree_width = nil, 30
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(win) then
      local buf = vim.api.nvim_win_get_buf(win)
      local ft = vim.api.nvim_get_option_value('filetype', { buf = buf })
      if ft == 'NvimTree' then
        tree_win = win
        tree_width = vim.api.nvim_win_get_width(win)
        break
      end
    end
  end

  -- Use change_root if tree is visible (non-disruptive)
  if tree_win then
    pcall(api.tree.change_root, cwd)
  elseif opts.open_if_closed then
    -- Tree not visible but caller wants it open
    pcall(api.tree.open, { path = cwd })
  else
    -- Tree not visible and we shouldn't open it - just update last_synced
    M.last_synced_cwd = cwd
    return
  end

  -- Defer width restoration to let tree settle
  vim.defer_fn(function()
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_is_valid(win) then
        local buf = vim.api.nvim_win_get_buf(win)
        local ft = vim.api.nvim_get_option_value('filetype', { buf = buf })
        if ft == 'NvimTree' then
          vim.api.nvim_win_set_width(win, tree_width)
          break
        end
      end
    end

    -- Restore focus
    if vim.api.nvim_win_is_valid(cur_win) then
      vim.api.nvim_set_current_win(cur_win)
    end
  end, 10)

  M.last_synced_cwd = cwd
end

function M.refresh()
  if M.status_win and vim.api.nvim_win_is_valid(M.status_win) then
    M.show_status()
  end

  local state = M.read_state()
  if state and state.cwd and state.cwd ~= vim.NIL then
    local cwd = state.cwd

    -- Change neovim's working directory (affects telescope, etc.)
    if cwd ~= vim.fn.getcwd() then
      vim.cmd('cd ' .. vim.fn.fnameescape(cwd))
    end

    M.sync_nvim_tree(cwd)
  end
end

return M
