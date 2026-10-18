-- Run after `lake build L4sh.Shell repl`:
-- nvim --headless -u NONE -i NONE -n -c 'luafile tests/direnv.lua'
local root = vim.fn.getcwd()
package.path = root .. '/L4sh/?.lua;' .. package.path
local repl = require('repl')
local output = require('output')
local temp = vim.fn.tempname()
local project = temp .. "/project 'quoted'"
local other = temp .. '/other'
for _, path in ipairs({ project .. '/nested', project .. '/bin', other,
    temp .. '/config/direnv', temp .. '/data', temp .. '/tmp' }) do
  vim.fn.mkdir(path, 'p')
end
-- Isolate approval/config files and inherited direnv state from the developer.
for key in pairs(vim.fn.environ()) do
  if key:match('^DIRENV_') then vim.env[key] = nil end
end
vim.env.XDG_CONFIG_HOME = temp .. '/config'
vim.env.XDG_DATA_HOME = temp .. '/data'
vim.env.L4SH_DIRENV_TEST = 'base'
vim.env.L4SH_DIRENV_REMOVE = 'present'
vim.env.LEAN_SHELL_STATE = temp .. '/state.json'
vim.env.L4SH_SESSION_DIR = temp
vim.env.TMPDIR = temp .. '/tmp'
vim.fn.writefile({ vim.json.encode({ version = 1, cwd = temp, files = {}, git = vim.NIL }) },
  vim.env.LEAN_SHELL_STATE)
vim.fn.writefile({ 'export L4SH_DIRENV_TEST="project value"',
  'unset L4SH_DIRENV_REMOVE', 'PATH_add bin', 'log_status "using test environment"',
  'echo "setup stdout"',
  [=[if [[ -e warn ]]; then printf '\033[33mmise WARN test warning\033[0m\n' >&2; fi]=],
  [=[if [[ -e fail ]]; then log_error 'SETUP_FAILED'; exit 1; fi]=],
}, project .. '/.envrc')
vim.fn.writefile({ 'export L4SH_DIRENV_TEST=other' }, other .. '/.envrc')
vim.fn.writefile({ '#!/bin/sh', 'printf PATH_OK' }, project .. '/bin/l4sh-direnv-tool')
vim.fn.setfperm(project .. '/bin/l4sh-direnv-tool', 'rwx------')

local function wait_for(predicate, message)
  local deadline = vim.uv.now() + 15000
  while not predicate() do
    assert(vim.uv.now() < deadline, message)
    coroutine.yield()
  end
end

local function response(cmd, raw)
  local result
  repl.send(raw and cmd or ('#eval_line 2\n$: ' .. cmd), function(resp) result = resp end)
  wait_for(function() return result end, 'REPL timed out: ' .. cmd)
  local messages, failed = {}, false
  for _, msg in ipairs(result.messages or {}) do
    messages[#messages + 1] = msg.data
    if msg.severity == 'error' then failed = true end
  end
  assert(not result.message, vim.inspect(result))
  return table.concat(messages, '\n'), failed
end

local function ok(cmd, raw)
  local text, failed = response(cmd, raw)
  assert(not failed, text)
  return text
end

local function cd(path) ok('cd ' .. vim.json.encode(path)) end
local function shell(cmd) return ok('sh ' .. vim.json.encode(cmd)) end
local probe = [[printf 'VALUE=%s REMOVE=%s\n' "$L4SH_DIRENV_TEST" "${L4SH_DIRENV_REMOVE-missing}"]]

local function run()
  assert(vim.fn.executable('direnv') == 1, 'direnv must be installed')
  repl.start(root)
  local loaded
  repl.load_session('import L4sh.Shell\ndirenv on\n$: sh "touch must-not-run"',
    function(resp) loaded = resp end)
  wait_for(function() return loaded end, 'session load timed out')
  for _, msg in ipairs(loaded.messages or {}) do assert(msg.severity ~= 'error', msg.data) end
  assert(vim.fn.filereadable(root .. '/must-not-run') == 0, 'loading ran a shell action')

  cd(project)
  local text, failed = response('sh "touch must-not-run"')
  assert(failed and text:find('blocked', 1, true), 'blocked .envrc diagnostic was lost: ' .. text)
  assert(not text:find('\27', 1, true) and not text:find('[31m', 1, true),
    'blocked .envrc error retained color codes: ' .. text)
  assert(vim.fn.filereadable(project .. '/must-not-run') == 0, 'blocked command executed')
  ok('direnvAllow')
  text = shell('echo hi')
  assert(text == 'hi', 'setup output leaked: ' .. text)
  vim.fn.writefile({}, project .. '/warn')
  text = shell('echo hi')
  assert(text == 'hi', 'setup warnings leaked: ' .. text)
  assert(table.concat(vim.fn.readfile(temp .. '/stream.txt'), '\n') == text,
    'live output differs from the cleaned final response')
  assert(shell('echo "command warning" >&2; echo hi') == 'command warning\nhi',
    'command stderr was hidden along with setup warnings')
  assert(ok('shsimple "echo hi"') == 'hi', 'shsimple leaked setup output')
  text, failed = response('sh "echo command-error >&2; exit 17"')
  assert(failed and text:find('command-error', 1, true) and not text:find('setup stdout', 1, true)
    and not text:find('mise WARN', 1, true), 'command failure replayed setup output: ' .. text)
  vim.fn.delete(project .. '/warn')
  vim.fn.writefile({}, project .. '/fail')
  text, failed = response('sh "touch must-not-run"')
  assert(failed and text:find('SETUP_FAILED', 1, true), 'direnv setup errors were hidden')
  assert(vim.fn.filereadable(project .. '/must-not-run') == 0, 'failed setup ran the command')
  vim.fn.delete(project .. '/fail')
  -- ANSI may be split across writes or lines; literal bracket text is ordinary output.
  text = shell([[printf '\033['; printf '32mgreen\033[0m\n';
    printf '\033]8;;https://example.com\033\\link\033]8;;\007\n';
    printf '\033[\n31mred\033[0m\nliteral [0m café\n']])
  assert(text:find('green\nlink\nred\nliteral [0m café', 1, true),
    'ANSI cleanup corrupted output: ' .. text)
  assert(shell(probe):find('VALUE=project value REMOVE=missing', 1, true))
  assert(shell('l4sh-direnv-tool'):find('PATH_OK', 1, true), 'PATH changes were ignored')
  assert(ok('shsimple ' .. vim.json.encode(probe)):find('VALUE=project value', 1, true))
  -- Lean helpers observe the same configuration, even within a single block.
  ok('do\n  cd "nested"\n  sh ' .. vim.json.encode('test "$L4SH_DIRENV_TEST" = "project value"'))
  assert(shell(probe):find('VALUE=project value', 1, true), 'parent .envrc was missed')

  -- A fresh worker must use the header and the persisted cwd.
  repl.restart(root)
  wait_for(function() return repl.is_ready() end, 'worker restart timed out')
  assert(shell(probe):find('VALUE=project value', 1, true))
  cd(other)
  ok('direnvAllow')
  assert(shell(probe):find('VALUE=other REMOVE=present', 1, true), 'project environment leaked')
  cd(temp)
  assert(shell(probe):find('VALUE=base REMOVE=present', 1, true), 'environment did not unload')

  cd(project)
  -- Reload changed .envrc contents on the next command, using normal approval.
  vim.fn.writefile({ 'export L4SH_DIRENV_TEST=changed',
    'echo "setup stdout"', 'echo "setup warning" >&2' }, project .. '/.envrc')
  ok('direnvAllow')
  assert(shell(probe):find('VALUE=changed', 1, true), 'changed .envrc was not loaded')

  -- Overlapping commands force the pool to initialize another worker.
  local replies = {}
  for i = 1, 2 do
    repl.send('#eval_line 2\n$: sh ' .. vim.json.encode('sleep 0.5; ' .. probe),
      function(resp) replies[i] = resp end)
  end
  wait_for(function() return replies[1] and replies[2] end, 'parallel commands timed out')
  assert(repl.status().workers >= 2, 'parallel test did not create another worker')
  for _, reply in ipairs(replies) do
    local found = false
    for _, msg in ipairs(reply.messages or {}) do
      assert(msg.severity ~= 'error', msg.data)
      found = found or msg.data:find('VALUE=changed', 1, true)
    end
    assert(found, 'new worker lost the direnv header')
  end

  -- Send a real Lean shi request through the actual Neovim response dispatcher.
  local state = require('state')
  state.show_status = function() end
  state.start_polling = function() end
  state.refresh = function() end
  vim.g.l4sh_project_root = root
  local app = dofile(root .. '/.nvim.lua')
  app.loaded_file = 'DirenvTest'
  vim.api.nvim_buf_set_name(0, root .. '/DirenvTest.lean')
  vim.api.nvim_buf_set_lines(0, 0, -1, false, {
    '$: shi ' .. vim.json.encode(probe .. '; test -t 0 && test -t 1 || exit 90; exit 7'),
  })
  output.init(temp .. '/output', nil)
  app.shell()
  wait_for(function() return output.terminals['1'] end, 'shi did not start')
  local term = output.terminals['1']
  wait_for(function() return not term.job end, 'shi did not exit')
  wait_for(function()
    return table.concat(vim.api.nvim_buf_get_lines(term.buf, 0, -1, false), '\n')
      :find('[Process exited', 1, true)
  end, 'terminal output was not rendered')
  local screen = table.concat(vim.api.nvim_buf_get_lines(term.buf, 0, -1, false), '\n')
  assert(screen:find('VALUE=changed REMOVE=present', 1, true), screen)
  assert(not screen:find('setup', 1, true) and not screen:find('direnv: loading', 1, true),
    'shi leaked setup output: ' .. screen)
  assert(screen:find('[Process exited 7]', 1, true), 'shi lost exit status or PTY: ' .. screen)

  -- The quiet launcher must still deliver foreground signals to the command.
  local interrupt = vim.json.decode(ok('shi ' .. vim.json.encode(
    "trap 'exit 42' INT; printf 'INT_READY\\n'; while :; do sleep 1; done"))).__l4sh_terminal__
  local interrupt_code
  output.run_shell(interrupt.cmd, interrupt.cwd, 2, function(code) interrupt_code = code end,
    interrupt.argv)
  local interrupt_term = output.terminals['2']
  wait_for(function()
    return table.concat(vim.api.nvim_buf_get_lines(interrupt_term.buf, 0, -1, false), '\n')
      :find('INT_READY', 1, true)
  end, 'interactive command did not start')
  vim.fn.chansend(interrupt_term.job, '\003')
  wait_for(function() return interrupt_code ~= nil end, 'Ctrl-C did not reach the command')
  assert(interrupt_code == 42, 'quiet launcher changed the signal handler exit status')
  assert(#vim.fn.glob(temp .. '/tmp/l4sh-direnv.*', false, true) == 0,
    'setup logs were not removed')

  text, failed = response('sh "exit 17"')
  assert(failed and text:find('exit code 17', 1, true), 'sh lost exit status')
  assert(ok('#eval L4sh.Direnv.active.get', true):find('false', 1, true),
    'failed action leaked direnv configuration')
  -- Reloading a header must update every worker, including direnv off.
  loaded = nil
  repl.load_session('import L4sh.Shell\ndirenv off', function(resp) loaded = resp end)
  wait_for(function() return loaded end, 'header reload timed out')
  assert(shell(probe):find('VALUE=base REMOVE=present', 1, true), 'direnv off had no effect')
  assert(vim.env.L4SH_DIRENV_TEST == 'base', 'project environment leaked to Neovim')

  -- Simulate launching l4sh from a shell that already loaded a project.
  local exported = vim.system({ 'direnv', 'export', 'json' }, { cwd = project, text = true }):wait()
  assert(exported.code == 0, exported.stderr)
  local before = vim.fn.environ()
  local delta = vim.json.decode(exported.stdout)
  for key, value in pairs(delta) do vim.env[key] = value ~= vim.NIL and value or nil end
  repl.stop()
  repl.start(root)
  loaded = nil
  repl.load_session('import L4sh.Shell\ndirenv on', function(resp) loaded = resp end)
  wait_for(function() return loaded end, 'inherited environment worker timed out')
  cd(temp)
  assert(shell(probe):find('VALUE=base REMOVE=present', 1, true),
    'launching inside a project prevented environment unloading')
  for key in pairs(delta) do vim.env[key] = before[key] end
end

local test = coroutine.create(function()
  local success, err = xpcall(run, debug.traceback)
  repl.stop()
  output.close_all_terminals()
  vim.fn.delete(temp, 'rf')
  if not success then
    io.stderr:write(err .. '\n')
    vim.cmd('cquit 1')
  end
  print('Direnv integration tests passed')
  vim.cmd('qa!')
end)
local function resume()
  local success, err = coroutine.resume(test)
  assert(success, err)
  if coroutine.status(test) ~= 'dead' then vim.defer_fn(resume, 10) end
end
resume()
