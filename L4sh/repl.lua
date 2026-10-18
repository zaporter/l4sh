-- REPL Worker Pool for l4sh
-- Manages multiple `lake exe repl` processes for parallel command execution
-- Dynamically scales pool size based on demand

local M = {}

--------------------------------------------------------------------------------
-- Configuration
--------------------------------------------------------------------------------

M.min_workers = 1       -- Minimum workers to keep alive
M.max_workers = 32      -- Maximum workers to spawn
M.idle_timeout = 30000  -- Shut down idle workers after 30s
M.root = nil
M.session_env = {}      -- Session-specific env vars to pass to workers

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

-- Worker pool: array of worker objects
-- Each worker: { id, job, env, busy, ready, output_buffer, current_request, last_active }
M.workers = {}
M.next_worker_id = 1

-- Pending command queue
M.queue = {}

-- Initialization command (loaded into all workers)
M.init_cmd = nil

-- Idle checker timer
M.idle_timer = nil

--------------------------------------------------------------------------------
-- Worker Management (internal)
--------------------------------------------------------------------------------

local function handle_response(worker, json_str)
  local ok, resp = pcall(vim.json.decode, json_str)
  if not ok then
    local json_start = json_str:find('{')
    if json_start then
      ok, resp = pcall(vim.json.decode, json_str:sub(json_start))
    end
  end

  if not ok or not resp then return end

  if resp.env then
    worker.env = resp.env
  end

  local req = worker.current_request
  worker.current_request = nil
  worker.busy = false
  worker.last_active = vim.uv.hrtime()

  if req then
    if req.is_init then
      worker.ready = true
    end

    if req.callback then
      vim.schedule(function()
        req.callback(resp)
      end)
    end
  end

  vim.schedule(function()
    M.process_queue()
  end)
end

local function remove_worker(worker)
  if worker.job then
    vim.fn.jobstop(worker.job)
  end
  for i, w in ipairs(M.workers) do
    if w == worker then
      table.remove(M.workers, i)
      break
    end
  end
end

local function create_worker()
  local id = M.next_worker_id
  M.next_worker_id = M.next_worker_id + 1

  local worker = {
    id = id,
    job = nil,
    env = nil,
    busy = false,
    ready = false,
    output_buffer = "",
    current_request = nil,
    last_active = vim.uv.hrtime(),
  }

  -- Build env table: inherit current env + session-specific vars
  local job_env = vim.fn.environ()
  for k, v in pairs(M.session_env) do
    job_env[k] = v
  end

  worker.job = vim.fn.jobstart({'lake', 'exe', 'repl'}, {
    cwd = M.root,
    env = job_env,
    stdin = 'pipe',
    stdout_buffered = false,
    stderr_buffered = false,
    on_stdout = function(_, data, _)
      for _, line in ipairs(data) do
        if line ~= '' then
          if worker.current_request and worker.current_request.on_output then
            local on_output = worker.current_request.on_output
            vim.schedule(function()
              on_output(line)
            end)
          end

          worker.output_buffer = worker.output_buffer .. line

          if line:match('}%s*$') then
            local response = worker.output_buffer
            worker.output_buffer = ""
            handle_response(worker, response)
          end
        end
      end
    end,
    on_stderr = function(_, _, _) end,
    on_exit = function(_, _, _)
      worker.job = nil
      worker.env = nil
      worker.busy = false
      worker.ready = false
      worker.current_request = nil
      -- Remove from pool on exit
      vim.schedule(function()
        for i, w in ipairs(M.workers) do
          -- IDs are reused after restart. A late exit from the old pool must
          -- not remove a newly initialized worker with the same ID.
          if w == worker then
            table.remove(M.workers, i)
            break
          end
        end
      end)
    end,
  })

  if not worker.job or worker.job <= 0 then
    return nil
  end

  return worker
end

local function send_to_worker(worker, req)
  worker.busy = true
  worker.current_request = req
  worker.last_active = vim.uv.hrtime()

  local request = { cmd = req.cmd }
  if req.use_env ~= false and worker.env then
    request.env = worker.env
  end

  local json = vim.json.encode(request) .. '\n\n'
  vim.fn.chansend(worker.job, json)
end

local function init_worker(worker, callback)
  if not M.init_cmd then
    worker.ready = true
    if callback then callback() end
    return
  end

  send_to_worker(worker, {
    cmd = M.init_cmd,
    is_init = true,
    use_env = false,
    callback = callback,
  })
end

local function find_available_worker()
  for _, worker in ipairs(M.workers) do
    if worker.job and worker.ready and not worker.busy then
      return worker
    end
  end
  return nil
end

local function count_live_workers()
  local count = 0
  for _, worker in ipairs(M.workers) do
    if worker.job then count = count + 1 end
  end
  return count
end

-- Spawn a new worker and initialize it
local function spawn_worker(callback)
  if count_live_workers() >= M.max_workers then
    if callback then callback(nil) end
    return
  end

  local worker = create_worker()
  if not worker then
    if callback then callback(nil) end
    return
  end

  table.insert(M.workers, worker)
  init_worker(worker, function(resp)
    if callback then callback(worker, resp) end
  end)
end

-- Check for and remove idle workers
local function check_idle_workers()
  if count_live_workers() <= M.min_workers then return end

  local now = vim.uv.hrtime()
  local timeout_ns = M.idle_timeout * 1e6

  for i = #M.workers, 1, -1 do
    local worker = M.workers[i]
    if worker.job and worker.ready and not worker.busy then
      local idle_time = now - worker.last_active
      if idle_time > timeout_ns and count_live_workers() > M.min_workers then
        vim.fn.jobstop(worker.job)
        table.remove(M.workers, i)
      end
    end
  end
end

local function start_idle_timer()
  if M.idle_timer then return end
  M.idle_timer = vim.uv.new_timer()
  M.idle_timer:start(M.idle_timeout, M.idle_timeout, vim.schedule_wrap(function()
    check_idle_workers()
  end))
end

local function stop_idle_timer()
  if M.idle_timer then
    M.idle_timer:stop()
    M.idle_timer:close()
    M.idle_timer = nil
  end
end

--------------------------------------------------------------------------------
-- Queue Processing
--------------------------------------------------------------------------------

function M.process_queue()
  -- Try to dispatch queued commands to available workers
  while #M.queue > 0 do
    local worker = find_available_worker()

    if not worker then
      -- No worker available - try to spawn one if under limit
      if count_live_workers() < M.max_workers then
        spawn_worker(function(new_worker)
          if new_worker then
            vim.schedule(function()
              M.process_queue()
            end)
          end
        end)
      end
      break
    end

    local req = table.remove(M.queue, 1)
    send_to_worker(worker, req)
  end
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

function M.start(root, initial_workers)
  if #M.workers > 0 then return end

  M.root = root or vim.fs.root(0, {'lakefile.lean', 'lakefile.toml', 'lean-toolchain'}) or vim.fn.getcwd()
  local count = initial_workers or M.min_workers

  for _ = 1, count do
    local worker = create_worker()
    if worker then
      worker.ready = (M.init_cmd == nil)
      table.insert(M.workers, worker)
    end
  end

  start_idle_timer()

  if #M.workers > 0 then
    vim.notify('REPL pool: ' .. #M.workers .. ' workers', vim.log.levels.INFO)
  else
    vim.notify('Failed to start REPL workers', vim.log.levels.ERROR)
  end
end

function M.stop()
  stop_idle_timer()
  for _, worker in ipairs(M.workers) do
    if worker.job then
      vim.fn.jobstop(worker.job)
    end
  end
  M.workers = {}
  M.queue = {}
  M.init_cmd = nil
  M.next_worker_id = 1
end

function M.restart(root)
  local init_cmd = M.init_cmd
  M.stop()
  M.start(root)
  if init_cmd then
    M.init_cmd = init_cmd
    M.init_all_workers()
  end
end

function M.init_all_workers(callback)
  local live_workers = {}
  for _, worker in ipairs(M.workers) do
    if worker.job then
      table.insert(live_workers, worker)
      worker.ready = false
    end
  end

  if #live_workers == 0 then
    if callback then callback() end
    return
  end

  local pending = #live_workers
  local first_response = nil

  local function on_worker_init(resp)
    if not first_response then
      first_response = resp
    end
    pending = pending - 1
    if pending == 0 and callback then
      callback(first_response)
    end
  end

  for _, worker in ipairs(live_workers) do
    init_worker(worker, on_worker_init)
  end
end

function M.load_session(content, callback)
  M.init_cmd = content
  M.init_all_workers(callback)
end

function M.import_module(module, callback)
  M.init_cmd = 'import ' .. module
  M.init_all_workers(callback)
end

function M.send(cmd, callback, use_env, on_output, eval_id)
  if #M.workers == 0 then
    vim.notify('REPL not running', vim.log.levels.ERROR)
    return false
  end

  table.insert(M.queue, {
    cmd = cmd,
    callback = callback,
    on_output = on_output,
    eval_id = eval_id,
    use_env = use_env,
  })

  M.process_queue()
  return true
end

function M.is_running()
  for _, worker in ipairs(M.workers) do
    if worker.job then return true end
  end
  return false
end

function M.is_ready()
  for _, worker in ipairs(M.workers) do
    if worker.job and worker.ready then return true end
  end
  return false
end

function M.is_pending(eval_id)
  for _, worker in ipairs(M.workers) do
    if worker.current_request and worker.current_request.eval_id == eval_id then
      return true
    end
  end
  for _, req in ipairs(M.queue) do
    if req.eval_id == eval_id then
      return true
    end
  end
  return false
end

function M.active_count()
  local count = #M.queue
  for _, worker in ipairs(M.workers) do
    if worker.busy then
      count = count + 1
    end
  end
  return count
end

function M.status()
  local ready, busy, initializing = 0, 0, 0
  for _, worker in ipairs(M.workers) do
    if worker.job then
      if worker.busy then
        busy = busy + 1
      elseif worker.ready then
        ready = ready + 1
      else
        initializing = initializing + 1
      end
    end
  end
  return {
    workers = count_live_workers(),
    ready = ready,
    busy = busy,
    initializing = initializing,
    queued = #M.queue,
    max = M.max_workers,
  }
end

-- Configure pool limits
function M.configure(opts)
  if opts.min_workers then M.min_workers = opts.min_workers end
  if opts.max_workers then M.max_workers = opts.max_workers end
  if opts.idle_timeout then M.idle_timeout = opts.idle_timeout end
end

-- Set session-specific environment variables
-- This restarts all workers to pick up the new env
function M.set_session_env(env)
  M.session_env = env or {}
  -- Restart workers to pick up new env
  if M.is_running() then
    M.restart(M.root)
  end
end

return M
