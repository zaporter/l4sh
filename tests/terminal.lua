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
  local terminal = require('terminal')
  local source = '\27[31mred\27[0m\27[s\27[20;1Hmenu\27[uend'
  local expected = '\27[31mred\27[0m\27' .. '7\27[20;1Hmenu\27' .. '8end'
  -- PTY read boundaries can split any part of an escape sequence.
  for split = 0, #source do
    local filter = terminal.new_filter()
    assert(filter.feed(source:sub(1, split)) .. filter.feed(source:sub(split + 1)) ..
      filter.finish() == expected, 'fragmented cursor sequence was corrupted')
  end
  local opaque = '\27]2;title\27[s\7\27Ppayload\27[u\27\\' ..
    '\27[?69h\27[s\27[?69l\27[3;9s'
  local filter = terminal.new_filter()
  local pieces = {}
  for i = 1, #opaque do pieces[#pieces + 1] = filter.feed(opaque:sub(i, i)) end
  assert(table.concat(pieces) .. filter.finish() == opaque, 'unrelated terminal sequences changed')

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
    menu)
      set -- $(stty size)
      printf '\033[2J\033[HLOG_BEFORE\r\n\033[s\033[%s;1Hw Enable Watch   d Detach\033[uLOG_AFTER\r\n' "$1"
      ;;
    query)
      stty -icanon -echo
      printf '\033[2;3H\033[6n'
      IFS= read -r -d R reply
      printf '%sR' "$reply" > cursor-reply.txt
      stty icanon
      ;;
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

  vim.fn.chansend(term.job, 'menu\n')
  wait_for(function()
    local lines = vim.api.nvim_buf_get_lines(term.buf, 0, -1, false)
    local height = vim.api.nvim_win_get_height(output.win)
    local top = #lines - height + 1
    return lines[top] == 'LOG_BEFORE' and lines[top + 1] == 'LOG_AFTER' and
      lines[#lines] == 'w Enable Watch   d Detach'
  end, 'menu cursor restore erased or misplaced log output')

  vim.fn.chansend(term.job, 'query\n')
  wait_for(function()
    return vim.fn.filereadable(cwd .. '/cursor-reply.txt') == 1 and
      vim.fn.readfile(cwd .. '/cursor-reply.txt')[1] == '\27[2;3R'
  end, 'terminal query reply did not reach the child PTY')

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
  wait_for(function() return vim.api.nvim_get_mode().mode == 't' end,
    'terminal input mode was not entered')
  vim.api.nvim_input('\003') -- Exercise the renderer's input forwarding too.
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

  output.run_shell("printf 'WIPE_READY\\n'; exec sleep 60", cwd, 5)
  local wiped = output.terminals['5']
  wait_for(function() return contents(wiped.buf):find('WIPE_READY') end,
    'buffer-wipe test did not start')
  local wiped_job = wiped.job
  vim.api.nvim_buf_delete(wiped.buf, { force = true })
  assert(vim.fn.jobwait({ wiped_job }, 5000)[1] ~= -1, 'wiping the buffer left its child running')
  assert(output.terminals['5'] == nil, 'wiped terminal remained tracked')
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
