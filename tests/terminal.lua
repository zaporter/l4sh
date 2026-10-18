-- Run from the project root after `lake build L4sh.Shell`:
-- nvim --headless -u NONE -i NONE -n -c 'luafile tests/terminal.lua'
local root = vim.fn.getcwd()
package.path = root .. '/L4sh/?.lua;' .. package.path
local output = require('output')
local temp = vim.fn.tempname()
vim.env.NVIM_LOG_FILE = temp .. '.log'
local cwd = temp .. '/work "quoted" \\dir'
vim.fn.mkdir(cwd, 'p')

local function wait_for(predicate, message)
  local deadline = vim.uv.now() + 5000
  while not predicate() do
    assert(vim.uv.now() < deadline, message)
    -- Return to Neovim's main loop so terminal resize events are delivered.
    coroutine.yield()
  end
end

local function contents(buf)
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
end

local function run()
  vim.o.columns = 160
  vim.o.lines = 45
  vim.o.hidden = false -- The terminal must survive hiding independently of this.

  -- Exercise Lean's JSON serialization and the actual response dispatcher.
  local command = [[
test -t 0 && test -t 1 && test -t 2 || exit 90
stty -echo
printf '%s' "$PWD" > cwd.txt
stty size > initial-size.txt
trap 'stty size > resized.txt' WINCH
printf 'READY:%s\n' "$TERM"
while :; do
  IFS= read -r action || continue
  case "$action" in
    draw) printf '\033[2J\033[Hobsolete text\r\033[2Kclean line\nsecond line\n';;
    long) printf '\033[2J\033[H'; printf '%180s\n' '' | tr ' ' 'x'; printf 'END_LONG\n';;
    size) stty size > requested-size.txt;;
    quit) exit 7;;
  esac
done
]]
  local result = vim.system({
    'lake', 'env', 'lean', '--run', 'tests/terminal_request.lean', cwd, command,
  }, { text = true }):wait()
  assert(result.code == 0, result.stderr)
  local request = vim.json.decode(result.stdout).__l4sh_terminal__
  assert(request.cmd == command and request.cwd == cwd, 'request lost quoting or cwd')

  -- Substitute only REPL transport; the request above comes from real Lean shi.
  package.loaded.repl = {
    start = function() end,
    is_running = function() return true end,
    import_module = function(_, callback) callback({}) end,
    send = function(_, callback)
      callback({ messages = { { severity = 'information', data = result.stdout } } })
    end,
  }
  local state = require('state')
  state.show_status = function() end
  state.start_polling = function() end
  state.refresh = function() end
  vim.g.l4sh_project_root = root
  local app = dofile(root .. '/.nvim.lua')
  output.init(temp .. '/output', nil)
  vim.api.nvim_buf_set_name(0, temp .. '/Test.lean')
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { '$: shi "test"' })
  app.shell()
  local term = assert(output.terminals['1'], 'shi did not open a terminal')
  wait_for(function() return contents(term.buf):find('READY:xterm%-256color') end,
    'command did not get a real terminal')
  assert(vim.fn.readfile(cwd .. '/cwd.txt')[1] == cwd, 'command ran in wrong directory')

  local function assert_size(path)
    local expected = vim.api.nvim_win_get_height(output.win) .. ' ' ..
      vim.api.nvim_win_get_width(output.win)
    wait_for(function()
      return vim.fn.filereadable(path) == 1 and vim.fn.readfile(path)[1] == expected
    end, 'PTY dimensions did not match the output pane: ' .. expected)
  end
  assert_size(cwd .. '/initial-size.txt')
  vim.api.nvim_win_set_width(output.win, 55)
  vim.api.nvim_win_set_height(output.win, 20)
  -- Headless Neovim has no UI resize notifications; exercise the same handler.
  vim.api.nvim_exec_autocmds('WinResized', {})
  -- Some shells defer traps while blocked in read; let read complete.
  vim.fn.chansend(term.job, 'size\n')
  assert_size(cwd .. '/resized.txt') -- Requires SIGWINCH to reach the child.

  vim.fn.chansend(term.job, 'long\n')
  wait_for(function()
    return contents(term.buf):gsub('\n', ''):find(string.rep('x', 180) .. 'END_LONG', 1, true)
  end, 'long log line was corrupted while wrapping')
  vim.fn.chansend(term.job, 'draw\n')
  wait_for(function()
    local text = contents(term.buf)
    return text:find('clean line\nsecond line') and not text:find('obsolete text')
  end, 'terminal redraw or input failed')

  local job = term.job
  output.hide()
  assert(output.has_terminal('1'), 'hiding the pane killed the terminal')
  output.show_for_id('1')
  vim.cmd('redraw')
  assert(term.job == job and vim.api.nvim_win_get_buf(output.win) == term.buf,
    'reopening the pane replaced the terminal')
  vim.fn.chansend(job, 'size\n')
  assert_size(cwd .. '/requested-size.txt')

  vim.fn.chansend(job, 'quit\n')
  wait_for(function() return term.job == nil end, 'terminal did not exit')
  assert(output.load('1')[2] == 'Exit code: 7', 'command exit status was lost')
  assert(contents(term.buf):find('clean line'), 'finished terminal lost scrollback')

  -- Ctrl-C must reach the foreground process through the PTY.
  local exit_code
  output.run_shell("trap 'exit 42' INT; printf 'INT_READY\\n'; while :; do sleep 1; done",
    cwd, 2, function(code) exit_code = code end)
  local interrupt_term = output.terminals['2']
  wait_for(function() return contents(interrupt_term.buf):find('INT_READY') end,
    'interrupt test did not start')
  vim.fn.chansend(interrupt_term.job, '\003')
  wait_for(function() return exit_code ~= nil end, 'Ctrl-C did not reach the command')
  assert(exit_code == 42, 'foreground signal handler did not run')

  output.run_shell("printf 'CLOSE_READY\\n'; exec sleep 60", cwd, 3)
  local closing = output.terminals['3']
  wait_for(function() return contents(closing.buf):find('CLOSE_READY') end,
    'close test did not start')
  local closing_job = closing.job
  output.close_terminal('3')
  assert(vim.fn.jobwait({ closing_job }, 5000)[1] ~= -1, 'closed terminal kept running')
  assert(not vim.api.nvim_buf_is_valid(closing.buf), 'closed terminal buffer survived')

  local failure_code, failure_message
  local notify = vim.notify
  vim.notify = function(message) failure_message = message end
  output.run_shell('true', temp .. '/missing', 4, function(code) failure_code = code end)
  vim.notify = notify
  assert(failure_code == 127 and failure_message:find('Failed to start terminal'),
    'terminal launch failure was not reported')
  assert(output.terminals['4'] == nil, 'failed terminal was tracked as running')
end

local test = coroutine.create(function()
  local ok, err = xpcall(run, debug.traceback)
  output.close_all_terminals()
  vim.fn.delete(temp, 'rf')
  vim.fn.delete(temp .. '.log')
  if not ok then
    io.stderr:write(err .. '\n')
    vim.cmd('cquit 1')
  end
  print('Terminal integration tests passed')
  vim.cmd('qa!')
end)
local function resume()
  local ok, err = coroutine.resume(test)
  assert(ok, err)
  if coroutine.status(test) ~= 'dead' then
    vim.defer_fn(resume, 10)
  end
end
resume()
