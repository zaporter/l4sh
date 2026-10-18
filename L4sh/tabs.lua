-- Tab management for l4sh
-- Provides clean separation between l4sh shell view and file editing view
--
-- Tab 1 (l4sh): nvim-tree | Shell.lean | output panel
-- Tab 2+ (edit): nvim-tree | file buffer(s)

local M = {}

--------------------------------------------------------------------------------
-- Tab identification
--------------------------------------------------------------------------------

-- Check if a tab is the l4sh tab
function M.is_l4sh_tab(tabnr)
  tabnr = tabnr or vim.api.nvim_get_current_tabpage()
  local ok, val = pcall(vim.api.nvim_tabpage_get_var, tabnr, 'l4sh_tab')
  return ok and val == true
end

-- Mark current tab as the l4sh tab
function M.mark_as_l4sh_tab()
  vim.api.nvim_tabpage_set_var(0, 'l4sh_tab', true)
end

-- Find the l4sh tab number
function M.get_l4sh_tab()
  for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
    if M.is_l4sh_tab(tab) then
      return tab
    end
  end
  return nil
end

-- Find or get the edit tab (first non-l4sh tab, or nil if none)
function M.get_edit_tab()
  for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
    if not M.is_l4sh_tab(tab) then
      return tab
    end
  end
  return nil
end

--------------------------------------------------------------------------------
-- Tab navigation
--------------------------------------------------------------------------------

-- Go to the l4sh tab
function M.goto_l4sh_tab()
  local tab = M.get_l4sh_tab()
  if tab then
    vim.api.nvim_set_current_tabpage(tab)
    return true
  end
  return false
end

-- Go to the edit tab (create if needed)
function M.goto_edit_tab()
  local edit_tab = M.get_edit_tab()
  if edit_tab then
    vim.api.nvim_set_current_tabpage(edit_tab)
    return edit_tab
  end

  -- No edit tab exists, create one
  -- Save current state
  local l4sh_tab = M.get_l4sh_tab()

  -- Create new tab
  vim.cmd('tabnew')
  local new_tab = vim.api.nvim_get_current_tabpage()

  -- Open nvim-tree in the new tab (synced to current cwd)
  M.ensure_nvim_tree()

  return new_tab
end

--------------------------------------------------------------------------------
-- nvim-tree management
--------------------------------------------------------------------------------

-- Find nvim-tree window in current tab
function M.find_tree_window()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local buf = vim.api.nvim_win_get_buf(win)
    local ft = vim.api.nvim_get_option_value('filetype', { buf = buf })
    if ft == 'NvimTree' then
      return win
    end
  end
  return nil
end

-- Ensure nvim-tree is open in current tab
function M.ensure_nvim_tree()
  if M.find_tree_window() then
    return -- Already open
  end

  local ok, api = pcall(require, 'nvim-tree.api')
  if ok then
    -- Open tree at current working directory
    pcall(api.tree.open)
  end
end

-- Get the main editing window (non-tree, non-output window)
function M.find_main_window()
  local tree_win = M.find_tree_window()

  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if win ~= tree_win then
      local buf = vim.api.nvim_win_get_buf(win)
      local bufname = vim.api.nvim_buf_get_name(buf)
      local ft = vim.api.nvim_get_option_value('filetype', { buf = buf })

      -- Skip output panel and terminal buffers
      if not bufname:match('%[l4sh') and ft ~= 'NvimTree' then
        return win
      end
    end
  end

  return nil
end

--------------------------------------------------------------------------------
-- File opening
--------------------------------------------------------------------------------

-- Open a file in the edit tab
-- This is the main entry point for nvim-tree and telescope
function M.open_file(filepath)
  if not filepath or filepath == '' then return end

  -- Check if this is a Shell.lean file (should stay in l4sh tab)
  local session_dir = vim.g.l4sh_session_dir
  if session_dir then
    local shell_file = session_dir .. '/Shell.lean'
    if filepath == shell_file then
      M.goto_l4sh_tab()
      -- Find and focus the Shell.lean window
      for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        local buf = vim.api.nvim_win_get_buf(win)
        local name = vim.api.nvim_buf_get_name(buf)
        if name == shell_file then
          vim.api.nvim_set_current_win(win)
          return
        end
      end
      -- Not found in window, open it
      vim.cmd('edit ' .. vim.fn.fnameescape(filepath))
      return
    end
  end

  -- Regular file: open in edit tab
  M.goto_edit_tab()

  -- Find the main editing window (not tree)
  local main_win = M.find_main_window()
  if main_win then
    vim.api.nvim_set_current_win(main_win)
  else
    -- No main window, create one by moving right from tree
    local tree_win = M.find_tree_window()
    if tree_win then
      vim.api.nvim_set_current_win(tree_win)
      vim.cmd('wincmd l')
      -- If we're still in tree, create a split
      if vim.api.nvim_get_current_win() == tree_win then
        vim.cmd('rightbelow vsplit')
      end
    end
  end

  vim.cmd('edit ' .. vim.fn.fnameescape(filepath))
end

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
-- nvim-tree integration
--------------------------------------------------------------------------------

-- Setup nvim-tree buffer keymaps to use our tab system
-- Called via autocmd when nvim-tree buffer is entered
function M.setup_nvim_tree_keymaps(bufnr)
  local ok, api = pcall(require, 'nvim-tree.api')
  if not ok then return end

  local function opts(desc)
    return { desc = 'nvim-tree: ' .. desc, buffer = bufnr, noremap = true, silent = true, nowait = true }
  end

  -- Override Enter/o to use our tab system
  vim.keymap.set('n', '<CR>', function()
    local node = api.tree.get_node_under_cursor()
    if node and node.type == 'file' then
      M.open_file(node.absolute_path)
    elseif node and node.type == 'directory' then
      api.node.open.edit()
    end
  end, opts('Open in edit tab'))

  vim.keymap.set('n', 'o', function()
    local node = api.tree.get_node_under_cursor()
    if node and node.type == 'file' then
      M.open_file(node.absolute_path)
    elseif node and node.type == 'directory' then
      api.node.open.edit()
    end
  end, opts('Open in edit tab'))

  vim.keymap.set('n', '<2-LeftMouse>', function()
    local node = api.tree.get_node_under_cursor()
    if node and node.type == 'file' then
      M.open_file(node.absolute_path)
    elseif node and node.type == 'directory' then
      api.node.open.edit()
    end
  end, opts('Open in edit tab'))
end

--------------------------------------------------------------------------------
-- Telescope integration
--------------------------------------------------------------------------------

-- Create attach_mappings function for telescope pickers
-- Use this when calling telescope functions to override the default open action
function M.telescope_attach_mappings(prompt_bufnr, map)
  local actions = require('telescope.actions')
  local action_state = require('telescope.actions.state')

  -- Override default select
  actions.select_default:replace(function()
    actions.close(prompt_bufnr)
    local selection = action_state.get_selected_entry()
    if selection then
      local filepath = selection.path or selection.filename or selection.value
      if filepath then
        -- Handle relative paths
        if not filepath:match('^/') then
          filepath = vim.fn.getcwd() .. '/' .. filepath
        end
        M.open_file(filepath)
      end
    end
  end)

  return true
end

-- Wrapper for telescope.find_files that uses our tab system
function M.find_files(opts)
  opts = opts or {}
  opts.attach_mappings = M.telescope_attach_mappings
  require('telescope.builtin').find_files(opts)
end

-- Wrapper for telescope.live_grep that uses our tab system
function M.live_grep(opts)
  opts = opts or {}
  opts.attach_mappings = M.telescope_attach_mappings
  require('telescope.builtin').live_grep(opts)
end

-- Wrapper for telescope.git_files that uses our tab system
function M.git_files(opts)
  opts = opts or {}
  opts.attach_mappings = M.telescope_attach_mappings
  require('telescope.builtin').git_files(opts)
end

-- Wrapper for telescope.oldfiles that uses our tab system
function M.oldfiles(opts)
  opts = opts or {}
  opts.attach_mappings = M.telescope_attach_mappings
  require('telescope.builtin').oldfiles(opts)
end

return M
