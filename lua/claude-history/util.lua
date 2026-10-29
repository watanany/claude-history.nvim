-- 一覧とプレビューの表示や、コマンドの実行に使う小さな関数
local M = {}

-- コマンドを非同期で動かし、終わったらメインループで on_exit を呼ぶ
-- コマンドが見つからないときも、エラーで止めずに code = -1 で on_exit を呼ぶ
---@param cmd string[]
---@param opts vim.SystemOpts text = true は付けなくてよい
---@param on_exit fun(res: vim.SystemCompleted)
function M.spawn(cmd, opts, on_exit)
  local ok, err = pcall(vim.system, cmd, vim.tbl_extend("force", { text = true }, opts), vim.schedule_wrap(on_exit))
  if not ok then
    vim.schedule(function() on_exit({ code = -1, signal = 0, stdout = "", stderr = tostring(err) }) end)
  end
end

-- ISO 8601(UTC)をローカル時刻の「月/日 時:分」にする。読めなければ同じ幅の空白
---@param iso string
---@return string
function M.format_time(iso)
  local y, mo, d, h, mi, s = iso:match("^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
  if y then
    local now = os.time()
    local offset = os.difftime(now, os.time(os.date("!*t", now) --[[@as osdateparam]]))
    local t = os.time({ year = y, month = mo, day = d, hour = h, min = mi, sec = s }) + offset
    return os.date("%m/%d %H:%M", t) --[[@as string]]
  else
    return "           "
  end
end

---@param s string
---@param width integer
---@return string
function M.pad(s, width)
  return s .. string.rep(" ", math.max(0, width - vim.fn.strdisplaywidth(s)))
end

return M
