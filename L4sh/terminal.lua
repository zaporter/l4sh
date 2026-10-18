-- Neovim's libvterm supports DEC cursor save/restore (ESC 7/8), but ignores
-- the ANSI equivalents (CSI s/u) used by Docker Compose's interactive menu.
local M = {}

function M.new_filter()
  local state, pending, osc, margins = 'text', '', false, false
  return {
    feed = function(data)
      local out = {}
      local i = 1
      while i <= #data do
        local c = data:sub(i, i)
        if state == 'text' then
          local escape = data:find('\27', i, true)
          if not escape then
            out[#out + 1] = data:sub(i)
            break
          end
          out[#out + 1] = data:sub(i, escape - 1)
          state, pending, i = 'escape', '\27', escape
        elseif state == 'escape' then
          pending = pending .. c
          if c == '[' then
            state = 'csi'
          else
            out[#out + 1], pending = pending, ''
            if c == ']' or c == 'P' or c == '_' or c == '^' or c == 'X' then
              state, osc = 'string', c == ']'
            else
              state = 'text'
              if c == 'c' then margins = false end
            end
          end
        elseif state == 'csi' then
          pending = pending .. c
          if c:byte() >= 0x40 and c:byte() <= 0x7e then
            if pending == '\27[?69h' then margins = true end
            if pending == '\27[?69l' then margins = false end
            if pending == '\27[s' and not margins then pending = '\27' .. '7' end
            if pending == '\27[u' then pending = '\27' .. '8' end
            out[#out + 1], pending, state = pending, '', 'text'
          elseif c == '\27' then
            out[#out + 1], pending, state = pending:sub(1, -2), '\27', 'escape'
          end
        else
          -- OSC/DCS/APC payloads are opaque; never rewrite escape-like text in them.
          out[#out + 1] = c
          if (state == 'string_escape' and c == '\\') or (osc and c == '\7') then
            state = 'text'
          elseif c == '\27' then
            state = 'string_escape'
          else
            state = 'string'
          end
        end
        i = i + 1
      end
      return table.concat(out)
    end,
    finish = function()
      local rest = pending
      pending, state = '', 'text'
      return rest
    end,
  }
end

return M
