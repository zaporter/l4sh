-- l4sh neovim configuration entry point
-- This file sets up the l4sh environment and commands

local M = {}

--------------------------------------------------------------------------------
-- Setup: call this from init.vim/init.lua or via --cmd
--------------------------------------------------------------------------------

function M.setup(opts)
  opts = opts or {}

  -- Store project root
  local project_root = opts.project_root or vim.g.l4sh_project_root or vim.fn.getcwd()

  -- Add l4sh lua modules to runtime path
  local l4sh_dir = opts.l4sh_dir or (project_root .. "/L4sh")
  vim.opt.runtimepath:prepend(l4sh_dir)

  -- Store project root in session module
  local session = require('session')
  session.project_root = project_root

  -- Create user commands
  vim.api.nvim_create_user_command('L4shSessions', function()
    -- Use switch if already in a session, otherwise start fresh
    if vim.g.l4sh_session_dir then
      session.switch()
    else
      session.start()
    end
  end, { desc = 'Open l4sh session picker' })

  vim.api.nvim_create_user_command('L4shNew', function(args)
    if args.args and args.args ~= "" then
      session.new_named(args.args)
    else
      session.new_unnamed()
    end
  end, { nargs = '?', desc = 'Create new l4sh session (optional: name)' })

  vim.api.nvim_create_user_command('L4shNewNamed', function()
    session.new_named()
  end, { desc = 'Create new named l4sh session (prompts for name)' })

  -- Keymaps (optional, users can override)
  if opts.keymaps ~= false then
    vim.keymap.set('n', '<leader>ls', ':L4shSessions<CR>', { desc = 'l4sh: session picker/switch', silent = true })
    vim.keymap.set('n', '<leader>ln', ':L4shNew<CR>', { desc = 'l4sh: new session', silent = true })
    vim.keymap.set('n', '<leader>lN', ':L4shNewNamed<CR>', { desc = 'l4sh: new named session', silent = true })
  end
end

--------------------------------------------------------------------------------
-- Start: begin l4sh with session picker (main entry point)
--------------------------------------------------------------------------------

function M.start()
  local session = require('session')
  session.start()
end

return M
