-- Eval tracking for l4sh
-- Manages eval markers, block detection, and eval IDs

local M = {}

-- Marker symbol (integral around point - distinguishes from regular comments)
M.MARKER = '⨕'

-- Session directory (set by init)
M.session_dir = nil

function M.init(session_dir)
  M.session_dir = session_dir
end

function M.is_session_file(filepath)
  return filepath and filepath:match('^' .. os.getenv("HOME") .. '/.l4sh/sessions/')
end

-- Get next eval ID from counter file
function M.next_id()
  if not M.session_dir then return 1 end

  local counter_file = M.session_dir .. '/eval_counter'
  local current = 0

  local f = io.open(counter_file, 'r')
  if f then
    current = tonumber(f:read('*a')) or 0
    f:close()
  end

  local next_id = current + 1
  f = io.open(counter_file, 'w')
  if f then
    f:write(tostring(next_id))
    f:close()
  end

  return next_id
end

-- Find eval marker for $: block at cursor (marker is on line above $:)
-- Returns: id, marker_line, command_line or nil
function M.get_block_at_cursor()
  local cursor_line = vim.fn.line('.')
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)

  for i = cursor_line, 1, -1 do
    local line = lines[i]
    if line:find('$:', 1, true) and not line:find(M.MARKER, 1, true) then
      if i > 1 then
        local prev_line = lines[i - 1]
        if prev_line:find(M.MARKER, 1, true) then
          local id = prev_line:match('#(%d+)')
          if id then
            return id, i - 1, i
          end
        end
      end
      return nil
    end
  end

  return nil
end

-- Find the $: block at cursor for execution
-- Returns: code, cmd_line, end_line, existing_id, marker_line
function M.get_shell_block()
  local cursor_line = vim.fn.line('.')
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)

  -- Find the $: line at or before cursor
  local start_line = nil
  for i = cursor_line, 1, -1 do
    local l = lines[i]
    if l:find('$:', 1, true) and not l:find(M.MARKER, 1, true) then
      start_line = i
      break
    end
    if l:find(M.MARKER, 1, true) then
      break
    end
  end

  if not start_line then return nil end

  local line = lines[start_line]

  -- Check for existing marker above
  local existing_id, marker_line = nil, nil
  if start_line > 1 then
    local prev_line = lines[start_line - 1]
    if prev_line:find(M.MARKER, 1, true) then
      existing_id = prev_line:match('#(%d+)')
      if existing_id then
        marker_line = start_line - 1
      end
    end
  end

  -- Collect continuation lines
  local block_lines = { line }
  local base_indent = (line:match('^(%s*)') or ''):len()
  local end_line = start_line

  for i = start_line + 1, #lines do
    local l = lines[i]
    if l:find('$:', 1, true) and not l:find(M.MARKER, 1, true) then break end
    if l:find(M.MARKER, 1, true) then break end
    if l:match('^%S') and l ~= '' then break end
    local indent = (l:match('^(%s*)') or ''):len()
    if l == '' or indent > base_indent then
      table.insert(block_lines, l)
      end_line = i
    else
      break
    end
  end

  return table.concat(block_lines, '\n'), start_line, end_line, existing_id, marker_line
end

-- Format duration for display
local function format_duration(ms)
  if not ms then return nil end
  if ms < 1000 then
    return string.format('%dms', ms)
  elseif ms < 60000 then
    return string.format('%.1fs', ms / 1000)
  else
    local mins = math.floor(ms / 60000)
    local secs = math.floor((ms % 60000) / 1000)
    return string.format('%dm%02ds', mins, secs)
  end
end

-- Build marker string
-- Format: /- ⨕ #N · HH:MM:SS [✓/✗] [(duration)] -/
function M.format_marker(id, status, indent, duration_ms)
  indent = indent or ''
  local timestamp = os.date('%H:%M:%S')
  local status_char = ''
  if status == 'ok' then
    status_char = ' ✓'
  elseif status == 'err' then
    status_char = ' ✗'
  end
  local duration_str = ''
  if duration_ms then
    duration_str = ' (' .. format_duration(duration_ms) .. ')'
  end
  return indent .. '/- ' .. M.MARKER .. ' #' .. id .. ' · ' .. timestamp .. status_char .. duration_str .. ' -/'
end

-- Insert or update eval marker
function M.set_marker(bufnr, cmd_line, existing_id, marker_line, id, status)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local cmd = lines[cmd_line]
  local indent = cmd:match('^(%s*)') or ''
  local marker = M.format_marker(id, status, indent)

  if existing_id and marker_line then
    vim.api.nvim_buf_set_lines(bufnr, marker_line - 1, marker_line, false, { marker })
  else
    vim.api.nvim_buf_set_lines(bufnr, cmd_line - 1, cmd_line - 1, false, { marker })
  end
end

-- Update marker status after execution
function M.update_status(bufnr, eval_id, status, duration_ms)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for i, line in ipairs(lines) do
    if line:find(M.MARKER, 1, true) and line:find('#' .. eval_id .. ' ', 1, true) then
      local indent = line:match('^(%s*)') or ''
      local new_marker = M.format_marker(eval_id, status, indent, duration_ms)
      vim.api.nvim_buf_set_lines(bufnr, i - 1, i, false, { new_marker })
      return i
    end
  end
  return nil
end

return M
