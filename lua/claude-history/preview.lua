-- 会話のプレビュー。バッファに発言を並べて書く(picker には依存しない)
local transcript = require("claude-term.transcript")
local util = require("claude-history.util")

local M = {}

local preview_limit = 20

M.ns = vim.api.nvim_create_namespace("claude-history.preview")

M.roles = {
  user = { label = "you", hl = "DiagnosticInfo" },
  assistant = { label = "claude", hl = "DiagnosticHint" },
}

-- 同じ話者が続く発言を 1 つにまとめる。messages は古い順
-- claude はツール呼び出しの合間に出す途中の発言を省き、ターンの最後の発言(最終回答)だけを残す
-- keep の発言は検索でヒットしたものなので、途中の発言でも消さずに残す
---@param messages ClaudeMessage[]
---@param keep? string uuid
---@return ClaudeMessage[]
function M.merge_turns(messages, keep)
  return vim.iter(messages):fold({}, function(turns, m)
    local last = turns[#turns]
    if last and last.role == m.role and m.role == "assistant" and not vim.list_contains(last.uuids, keep) then
      turns[#turns] = m
    elseif last and last.role == m.role and m.role == "user" then
      turns[#turns] = { role = m.role, time = m.time, text = last.text .. "\n\n" .. m.text, uuids = vim.list_extend(vim.list_slice(last.uuids), m.uuids) }
    else
      turns[#turns + 1] = m
    end
    return turns
  end)
end

-- rg がないと vim.system がエラーを投げる。プレビューを描くたびに止まらないよう、空を返す
---@param path string
---@return ClaudeMessage[]
local function read_messages(path)
  local ok, res = pcall(function()
    return vim.system({ "rg", "--no-filename", transcript.message_pattern, path }, { text = true }):wait(3000)
  end)
  local out = ok and res.stdout or ""
  return vim.iter(vim.split(out, "\n", { trimempty = true })):map(transcript.parse_message):totable()
end

---@type table<string, { stamp: string, messages: ClaudeMessage[] }>
local messages_cache = {}

-- 会話の全発言(まとめる前)。transcript が変わっていなければ前回の結果を返す
---@param id? string
---@return ClaudeMessage[]
function M.all_messages(id)
  local path = id and transcript.path(id)
  local stat = path and vim.uv.fs_stat(path)
  local stamp = stat and (stat.size .. ":" .. stat.mtime.sec) or ""
  local cached = id and messages_cache[id]
  if not stat then
    return {}
  elseif cached and cached.stamp == stamp then
    return cached.messages
  else
    messages_cache[id] = { stamp = stamp, messages = read_messages(path) }
    return messages_cache[id].messages
  end
end

-- 最新 preview_limit 件の発言
---@param id? string
---@return ClaudeMessage[]
function M.messages(id)
  local turns = M.merge_turns(M.all_messages(id))
  return vim.list_slice(turns, math.max(1, #turns - preview_limit + 1), #turns)
end

-- 発言を並べた行と、各発言の位置。発言の後には空行を入れ、その下に次の発言の区切り線(extmark)を出す
-- 先頭の発言の上にも区切り線を出すため、空行から始める(1 行目の上の virt_lines は表示されないことがある)
---@param messages ClaudeMessage[]
---@return { lines: string[], marks: { row: integer, count: integer, role: table, time: string, uuids: string[] }[] }
local function layout(messages)
  return vim.iter(messages):fold({ lines = { "" }, marks = {} }, function(acc, m)
    local body = vim.split(m.text, "\n", { plain = true })
    local mark = { row = #acc.lines, count = #body, role = M.roles[m.role], time = m.time, uuids = m.uuids }
    return {
      lines = vim.list_extend(vim.list_extend(acc.lines, body), { "" }),
      marks = vim.list_extend(acc.marks, { mark }),
    }
  end)
end

-- 会話を buf に書く
-- 話者ごとの区切り線と左の縦棒は、本文の見出しや区切り線と混ざらないよう、バッファに書かず extmark で付ける
-- 区切り線は折り返さないので、長めに作っておけばウィンドウの幅で切れる。色は話者名が目立つよう控えめな NonText にする
---@param buf integer
---@param win integer
---@param messages ClaudeMessage[]
function M.draw(buf, win, messages)
  local view = layout(messages)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, view.lines)
  vim.bo[buf].modifiable = false
  vim.iter(view.marks):each(function(mark)
    vim.api.nvim_buf_set_extmark(buf, M.ns, mark.row, 0, {
      virt_lines = {
        {
          { "── ", "NonText" },
          { mark.role.label, mark.role.hl },
          { "  " .. util.format_time(mark.time) .. " ", "Comment" },
          { ("─"):rep(300), "NonText" },
        },
      },
      virt_lines_above = true,
      virt_lines_leftcol = true,
    })
    vim.iter(vim.fn.range(mark.row, mark.row + mark.count - 1)):each(function(row)
      vim.api.nvim_buf_set_extmark(buf, M.ns, row, 0, { sign_text = "▎", sign_hl_group = mark.role.hl, priority = 100 })
    end)
  end)
  -- 狭いプレビューで本文の幅を取るため、行番号を消して折り返さない(各行の頭が見えれば会話を思い出せる)
  vim.wo[win].signcolumn = "yes:1"
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].wrap = false
  return view
end

-- 会話の最新の発言を buf に書き、win を最後までスクロールする
---@param buf integer
---@param win integer
---@param s ClaudeSession
function M.render_preview(buf, win, s)
  local view = M.draw(buf, win, M.messages(s.id))
  vim.api.nvim_win_set_cursor(win, { #view.lines, 0 })
end

return M
