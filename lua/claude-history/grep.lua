-- 会話の検索のうち、picker に依存しない部分。rg の引数、ヒットの解析、ヒットした所のプレビュー
local claude_term = require("claude-term")
local preview = require("claude-history.preview")
local text = require("claude-history.text")
local util = require("claude-term.util")

local M = {}

-- ヒットした発言の前後に出す発言の数
local hit_context = 10

---@class ClaudeHit
---@field session ClaudeSession
---@field uuid string
---@field role "user"|"assistant"
---@field time string
---@field line string ヒットした行
---@field terms string[] 色を付ける語
---@field matched? string[] line に含まれていた語(AI 検索のみ)

-- line の中の terms の位置(0 始まり、終わりは含まない)。重なった位置は 1 つにまとめる
-- rg の --smart-case と同じく、語に大文字がなければ大文字小文字を区別しない
---@param line string
---@param terms string[]
---@return { [1]: integer, [2]: integer }[]
function M.match_spans(line, terms)
  local spans = vim.iter(terms)
    :map(function(term)
      local ignore = term == term:lower()
      local hay = ignore and line:lower() or line
      local needle = ignore and term:lower() or term
      return vim.iter(hay:gmatch("()" .. vim.pesc(needle) .. "()")):map(function(s, e) return { s - 1, e - 1 } end):totable()
    end)
    :flatten()
    :totable()
  table.sort(spans, function(a, b) return a[1] < b[1] end)
  return vim.iter(spans):fold({}, function(acc, span)
    local last = acc[#acc]
    return last and span[1] < last[2]
        and vim.list_extend(vim.list_slice(acc, 1, #acc - 1), { { last[1], math.max(last[2], span[2]) } })
      or vim.list_extend(acc, { span })
  end)
end

-- live grep で動かす rg の引数
---@param query string
---@param paths string[] 本文のキャッシュ(text.paths)
---@return string[]
function M.rg_args(query, paths)
  return vim.list_extend({ "--no-heading", "--with-filename", "--null", "--fixed-strings", "--smart-case", "--", query }, paths)
end

-- rg の出力 1 行を検索結果にする。本文にヒットしていなければ nil
-- rg は行全体を見るので、role・uuid・time の列だけにヒットした行はここで除く
---@param line string
---@param query string
---@param by_id table<string, ClaudeSession>
---@return ClaudeHit?
function M.parse_hit(line, query, by_id)
  local row = text.parse_row(line, by_id)
  return row and #M.match_spans(row.line, { query }) > 0 and vim.tbl_extend("force", row, { terms = { query } }) or nil
end

-- ヒットした行を、マッチ部分が見える位置から切り出す。マッチ部分には hl を付ける
---@param line string
---@param terms string[]
---@param hl? string
---@return { [1]: string, [2]: string? }[]
function M.format_snippet(line, terms, hl)
  local first = M.match_spans(line, terms)[1] or { 0, 0 }
  local skip = math.max(0, vim.fn.strchars(line:sub(1, first[1])) - 20)
  local shown = skip > 0 and ("…" .. vim.fn.strcharpart(line, skip)) or line
  local acc = vim.iter(M.match_spans(shown, terms)):fold({ segs = {}, pos = 0 }, function(acc, span)
    return {
      segs = vim.list_extend(acc.segs, { { shown:sub(acc.pos + 1, span[1]) }, { shown:sub(span[1] + 1, span[2]), hl } }),
      pos = span[2],
    }
  end)
  return vim.list_extend(acc.segs, { { shown:sub(acc.pos + 1) } })
end

-- ヒットした発言の前後を buf に書き、win をヒットした行までスクロールする
---@param buf integer
---@param win integer
---@param hit ClaudeHit
function M.render_hit(buf, win, hit)
  local turns = preview.merge_turns(preview.all_messages(hit.session.id), hit.uuid)
  local at = vim.iter(turns):enumerate():find(function(_, t) return vim.list_contains(t.uuids, hit.uuid) end) or #turns
  local view = preview.draw(buf, win, vim.list_slice(turns, math.max(1, at - hit_context), at + hit_context))
  local mark = vim.iter(view.marks):find(function(m) return vim.list_contains(m.uuids, hit.uuid) end)
  local matches = vim.iter(view.lines):enumerate()
    :map(function(i, line)
      return vim.iter(M.match_spans(line, hit.terms)):map(function(span) return { row = i - 1, col = span[1], end_col = span[2] } end):totable()
    end)
    :flatten()
    :totable()
  local target = mark and vim.iter(matches):find(function(m) return m.row >= mark.row and m.row < mark.row + mark.count end)
  local pos = (target and { target.row, target.col }) or (mark and { mark.row, 0 }) or { #view.lines - 1, 0 }
  -- ヒットした発言の区切り線から見せる。ヒットした行が画面に入らないときは、その行の少し上から見せる
  local top = mark and pos[1] - mark.row < vim.api.nvim_win_get_height(win) - 2 and mark.row or pos[1] - 2
  vim.iter(matches):each(function(m)
    vim.api.nvim_buf_set_extmark(buf, preview.ns, m.row, m.col, { end_col = m.end_col, hl_group = "Search", priority = 200 })
  end)
  vim.api.nvim_win_call(win, function()
    vim.fn.winrestview({ lnum = pos[1] + 1, col = pos[2], topline = math.max(1, top + 1), topfill = 1 })
  end)
end

---@class ClaudeHistoryScope
---@field root? string
---@field sessions ClaudeSession[]
---@field by_id table<string, ClaudeSession>
---@field project_width integer

-- 検索の前の共通の準備。root の中の会話と、表示用の project 名の幅を cb に渡す
-- root で絞ったときはどれも同じプロジェクトなので、幅を 0 にして project 名を出さない
---@param root? string
---@param cb fun(scope: ClaudeHistoryScope)
function M.with_sessions(root, cb)
  claude_term.list(function(all)
    local sessions = vim.tbl_filter(util.in_root(root), all)
    local by_id = vim.iter(sessions):fold({}, function(acc, s)
      acc[s.id] = s
      return acc
    end)
    if #sessions == 0 then
      vim.notify("claude: 会話がありません" .. (root and (": " .. root) or ""), vim.log.levels.INFO)
    else
      cb({ root = root, sessions = sessions, by_id = by_id, project_width = root and 0 or util.project_width(sessions, 16) })
    end
  end)
end

---@param root? string
---@return string
function M.scope_label(root)
  return root and (" (" .. vim.fs.basename(vim.fs.normalize(root)) .. ")") or ""
end

return M
