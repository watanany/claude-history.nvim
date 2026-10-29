-- AI 検索(picker には依存しない)。live grep で見つからないときに使う。言い換えや、語を覚えていない会話を探す
-- 1. model(既定は haiku)が検索語を考える
-- 2. 発言の本文を rg で探し、BM25 で点数を付けて並べる
-- 3. 同じ model が上位を並べ替える
local config = require("claude-history.config")
local grep = require("claude-history.grep")
local text = require("claude-history.text")
local util = require("claude-history.util")
local claude_term = require("claude-term")

local M = {}

-- 上位の何件を model に並べ替えさせるか
local rerank_limit = 30

-- claude -p の返事を待つ時間(ミリ秒)。ふだんは 3 秒ほどで返る
local ask_timeout = 60000

local expand_prompt = table.concat({
  "あなたは検索語を考える係。ユーザーが過去の Claude Code との会話を探している。",
  "会話の本文に実際に出てきそうな語を 12〜20 個、JSON の文字列配列だけで返す。",
  "各語は空白を含まない 1 語(日本語の語、英単語、コマンド名、オプション名、ファイル名、関数名など)。",
  "日本語と英語の言い換え、表記ゆれを含める。説明やコードブロックは付けない",
})

local rerank_prompt = table.concat({
  "ユーザーが過去の Claude Code との会話を探している。候補はセッションごとに、タイトルと本文の抜粋を並べたもの。",
  "問いに合うセッションの番号を、合う順に最大 10 個、JSON の整数配列だけで返す。合わないものは入れない。説明は付けない",
})

-- claude -p で聞き、返事の中の JSON 配列を cb に渡す。失敗したら nil
-- ツール・MCP・設定を読まないようにすると 3 秒ほどで返る
-- prompt は標準入力で渡す。引数で渡すと、- で始まる質問がオプションとして読まれるため
---@param system_prompt string
---@param prompt string
---@param cb fun(value: any[]?)
local function ask_model(system_prompt, prompt, cb)
  util.spawn({
    claude_term.claude_cmd(), "-p", "--model", config.options.model, "--no-session-persistence",
    "--tools=", "--strict-mcp-config", "--setting-sources=", "--system-prompt", system_prompt,
  }, { stdin = prompt, timeout = ask_timeout }, function(res)
    local ok, value = pcall(vim.json.decode, res.code == 0 and (res.stdout or ""):match("%b[]") or "")
    cb(ok and type(value) == "table" and value or nil)
  end)
end

-- 非同期の処理をまとめて走らせ、すべて終わったら結果を順に cb に渡す
---@param tasks fun(done: fun(value: any))[]
---@param cb fun(...)
local function all(tasks, cb)
  local results, pending = {}, #tasks
  vim.iter(ipairs(tasks)):each(function(i, task)
    task(function(value)
      results[i] = value
      pending = pending - 1
      if pending == 0 then
        cb(unpack(results, 1, #tasks))
      end
    end)
  end)
end

-- 本文のキャッシュを terms で探し、ヒットした行を cb に渡す。terms が空なら rg を動かさない
---@param terms string[] 小文字
---@param scope ClaudeHistoryScope
---@param cb fun(hits: ClaudeHit[])
local function grep_text_cache(terms, scope, cb)
  if #terms == 0 then
    cb({})
  else
    util.spawn(vim.iter({
      { "rg", "--no-heading", "--with-filename", "--null", "--fixed-strings", "--ignore-case" },
      vim.iter(terms):map(function(t) return { "-e", t } end):flatten():totable(),
      { "--" },
      text.paths(scope.sessions),
    }):flatten():totable(), {}, function(res)
      cb(vim.iter(vim.split(res.stdout or "", "\n", { trimempty = true }))
        :map(function(l)
          local row = text.parse_row(l, scope.by_id)
          local low = row and row.line:lower()
          local matched = low and vim.tbl_filter(function(t) return low:find(t, 1, true) ~= nil end, terms) or {}
          return #matched > 0 and vim.tbl_extend("force", row, { terms = terms, matched = matched }) or nil
        end)
        :totable())
    end)
  end
end

-- 語ごとの BM25 で会話に点数を付ける。ヒットした行の数を語の出現回数とみなす
-- どこにでも出る語は点を低くし、長い会話は何にでも当たるので割り引く
---@param hits ClaudeHit[]
---@param sessions ClaudeSession[]
---@return table<string, number> session id → 点数
local function bm25(hits, sessions)
  local k, b = 1.2, 0.75
  local tf = vim.iter(hits):fold({}, function(acc, h)
    local counts = acc[h.session.id] or {}
    vim.iter(h.matched):each(function(t) counts[t] = (counts[t] or 0) + 1 end)
    acc[h.session.id] = counts
    return acc
  end)
  local df = vim.iter(pairs(tf)):fold({}, function(acc, _, counts)
    vim.iter(pairs(counts)):each(function(t) acc[t] = (acc[t] or 0) + 1 end)
    return acc
  end)
  local size = vim.iter(sessions):fold({}, function(acc, s)
    local stat = vim.uv.fs_stat(text.path(s.id))
    acc[s.id] = stat and stat.size or 0
    return acc
  end)
  local n = #sessions
  local avg = math.max(1, vim.iter(pairs(size)):fold(0, function(sum, _, v) return sum + v end) / n)
  return vim.iter(pairs(tf)):fold({}, function(acc, id, counts)
    local norm = 1 - b + b * size[id] / avg
    acc[id] = vim.iter(pairs(counts)):fold(0, function(score, t, c)
      local idf = math.log((n - df[t] + 0.5) / (df[t] + 0.5) + 1)
      return score + idf * c * (k + 1) / (c + k * norm)
    end)
    return acc
  end)
end

-- ヒットした行を、会話ごとに 1 件の結果にして点数の高い順に並べる
-- 一覧には、いちばん多くの語に当たった発言の、いちばん多くの語に当たった行を出す
-- excerpts は並べ替えで model に見せる抜粋(多くの語に当たった発言から 3 つ)
---@param hits ClaudeHit[]
---@param sessions ClaudeSession[]
---@return table[]
local function rank_sessions(hits, sessions)
  local scores = bm25(hits, sessions)
  local messages = vim.iter(hits):fold({}, function(acc, h)
    local key = h.session.id .. "\0" .. h.uuid
    local m = acc[key] or { terms = {}, best = h }
    vim.iter(h.matched):each(function(t) m.terms[t] = true end)
    m.best = #h.matched > #m.best.matched and h or m.best
    acc[key] = m
    return acc
  end)
  local by_session = vim.iter(pairs(messages)):fold({}, function(acc, _, m)
    local id = m.best.session.id
    acc[id] = vim.list_extend(acc[id] or {}, { m })
    return acc
  end)
  local items = vim.iter(pairs(by_session))
    :map(function(id, ms)
      table.sort(ms, function(x, y) return vim.tbl_count(x.terms) > vim.tbl_count(y.terms) end)
      local best = ms[1].best
      return vim.tbl_extend("force", best, {
        text = best.session.title .. " " .. best.line,
        score = scores[id],
        excerpts = vim.iter(ms):take(3):map(function(m) return m.best end):totable(),
      })
    end)
    :totable()
  table.sort(items, function(x, y) return x.score > y.score end)
  return vim.iter(ipairs(items)):map(function(i, item) return vim.tbl_extend("force", item, { rank = i }) end):totable()
end

-- 上位を model に並べ替えさせる。model が選んだものを先に、残りを元の順で後ろに置く
---@param query string
---@param items table[]
---@param cb fun(items: table[], ok: boolean)
local function rerank(query, items, cb)
  local candidates = vim.list_slice(items, 1, rerank_limit)
  local function excerpt(h)
    local snippet = table.concat(vim.iter(grep.format_snippet(h.line, h.terms)):map(function(seg) return seg[1] end):totable())
    return ("  - %s: %s"):format(h.role, vim.fn.strcharpart(snippet, 0, 120))
  end
  local listing = vim.iter(ipairs(candidates))
    :map(function(i, item)
      local head = ("[%d] %s (%s)"):format(i, item.session.title, item.session.project)
      return table.concat(vim.list_extend({ head }, vim.iter(item.excerpts):map(excerpt):totable()), "\n")
    end)
    :join("\n\n")
  ask_model(rerank_prompt, ("問い: %s\n\n%s"):format(query, listing), function(order)
    local picked = vim.iter(order or {})
      :filter(function(i) return type(i) == "number" and candidates[i] ~= nil end)
      :fold({}, function(acc, i) return vim.list_contains(acc, i) and acc or vim.list_extend(acc, { i }) end)
    local rest = vim.iter(ipairs(items)):filter(function(i) return not vim.list_contains(picked, i) end):map(function(_, item) return item end)
    local ordered = vim.list_extend(vim.iter(picked):map(function(i) return items[i] end):totable(), rest:totable())
    cb(vim.iter(ipairs(ordered)):map(function(i, item) return vim.tbl_extend("force", item, { rank = i }) end):totable(), order ~= nil)
  end)
end

-- query に合う会話を探し、途中の結果と状態を届くたびに cb に渡す。cb が false を返したら(picker を閉じたなど)そこでやめる
-- items は ClaudeHit に rank(並べた順)を足したもの。status は picker のタイトルに付ける文
---@param query string
---@param scope ClaudeHistoryScope
---@param cb fun(items: table[], status: string): boolean?
function M.run(query, scope, cb)
  all({
    function(done) ask_model(expand_prompt, query, done) end,
    function(done) text.update(scope.sessions, done) end,
  }, function(expanded)
    -- 検索語を出せなかったときは、入力を空白で区切った語で探す。1 文字の語は何にでも当たるので除く
    local terms = vim.iter(expanded or vim.split(query, "%s+", { trimempty = true }))
      :filter(function(t) return type(t) == "string" and vim.fn.strchars(t) >= 2 end)
      :map(string.lower)
      :fold({}, function(acc, t) return vim.list_contains(acc, t) and acc or vim.list_extend(acc, { t }) end)
    grep_text_cache(terms, scope, function(hits)
      local ranked = rank_sessions(hits, scope.sessions)
      if #ranked == 0 then
        cb({}, " (見つかりませんでした)")
      elseif cb(ranked, (expanded and "" or " (検索語を出せなかったので入力のまま)") .. " (並べ替え中…)") ~= false then
        rerank(query, ranked, function(reordered, ok)
          cb(reordered, ok and "" or " (並べ替えに失敗)")
        end)
      end
    end)
  end)
end

return M
