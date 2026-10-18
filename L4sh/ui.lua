-- UI elements for l4sh
-- Highlights, signs, and extmarks

local M = {}

local eval = require('eval')

M.ns = vim.api.nvim_create_namespace('l4sh_eval')

function M.setup()
  -- Highlight groups for status dots
  vim.api.nvim_set_hl(0, 'L4shSuccess', { fg = '#a6e3a1', bold = true })
  vim.api.nvim_set_hl(0, 'L4shError', { fg = '#f38ba8', bold = true })
  vim.api.nvim_set_hl(0, 'L4shPending', { fg = '#585b70' })

  -- Signs for gutter
  vim.fn.sign_define('L4shOk', { text = '●', texthl = 'L4shSuccess' })
  vim.fn.sign_define('L4shErr', { text = '●', texthl = 'L4shError' })
  vim.fn.sign_define('L4shPending', { text = '○', texthl = 'L4shPending' })
end

-- Update extmarks and signs for eval markers in buffer
function M.update_markers(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  vim.api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)
  vim.fn.sign_unplace('l4sh', { buffer = bufnr })

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for i, line in ipairs(lines) do
    if line:find(eval.MARKER, 1, true) then
      -- Determine status
      local sign_name = 'L4shPending'
      if line:find('✓', 1, true) then
        sign_name = 'L4shOk'
      elseif line:find('✗', 1, true) then
        sign_name = 'L4shErr'
      end

      -- Place sign on the $: line below
      if i < #lines then
        vim.fn.sign_place(0, 'l4sh', sign_name, bufnr, { lnum = i + 1 })
      end

      -- Dim the marker line
      vim.api.nvim_buf_set_extmark(bufnr, M.ns, i - 1, 0, {
        end_col = #line,
        hl_group = 'Comment',
      })
    end
  end
end

-- Find nvim-tree window
function M.find_tree_window()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    local ft = vim.api.nvim_get_option_value('filetype', { buf = buf })
    if ft == 'NvimTree' then
      return win
    end
  end
  return nil
end

-- Set winfixwidth on nvim-tree
function M.fix_tree_width()
  local win = M.find_tree_window()
  if win then
    vim.api.nvim_set_option_value('winfixwidth', true, { win = win })
  end
end

return M
