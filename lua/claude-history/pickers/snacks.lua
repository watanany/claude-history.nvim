-- Snacks.picker で検索結果を出す。picker に依存する部分はここだけに置く
local ask = require("claude-history.ask")
local claude_term = require("claude-term")
local claude_util = require("claude-term.util")
local config = require("claude-history.config")
local grep = require("claude-history.grep")
local preview = require("claude-history.preview")
local text = require("claude-history.text")
local util = require("claude-history.util")

local M = {}

-- 検索の picker の見た目と操作。live grep と AI 検索で共通
-- ヒットした行に幅を使うため、会話のタイトルは一覧に出さず、プレビューの枠に出す
---@param project_width integer
---@return table
local function hit_picker_opts(project_width)
  return {
    layout = { preset = "telescope" },
    format = function(item)
      local s = item.session
      local mark, mark_hl = claude_util.status_mark(s.status)
      return vim.list_extend({
        { mark .. " ", mark_hl },
        { util.format_time(item.time) .. "  ", "Comment" },
        { util.pad(vim.fn.strcharpart(s.project, 0, project_width), project_width), "Directory" },
        { " ▎ ", preview.roles[item.role].hl },
      }, grep.format_snippet(item.line, item.terms, "SnacksPickerMatch"))
    end,
    preview = function(ctx)
      ctx.preview:reset()
      ctx.preview:set_title(ctx.item.session.title)
      grep.render_hit(ctx.buf, ctx.win, ctx.item)
      ctx.preview:highlight({ ft = "markdown" })
    end,
    confirm = function(picker, item)
      picker:close()
      if item then
        claude_term.resume(item.session)
      end
    end,
  }
end

-- query に合う会話を AI 検索で探す picker を開く。結果は届いた順に picker に流し込む
---@param query string
---@param scope ClaudeHistoryScope
local function ask_picker(query, scope)
  local items = {}
  local base = "AI 検索" .. grep.scope_label(scope.root) .. ": " .. query
  local picker = Snacks.picker(vim.tbl_extend("force", hit_picker_opts(scope.project_width), {
    title = base .. " (検索語を考え中…)",
    -- 結果は後から届くので、0 件でも閉じない
    show_empty = true,
    -- 並べ替えた順に出す。入力した文字では、その中をさらに絞り込める
    matcher = { sort_empty = true },
    sort = { fields = { "rank" } },
    finder = function() return items end,
  }))
  ask.run(query, scope, function(new_items, status)
    if picker.closed then
      return false
    else
      items = new_items
      picker.title = base .. status
      picker:update_titles()
      picker:find()
    end
  end)
end

-- 先頭が ? の入力は、AI 検索への質問として扱う。? を外した文を返し、? で始まらなければ nil を返す
-- 日本語入力のまま打てるように、全角の「？」も受け付ける
---@param input string
---@return string?
local function question_of(input)
  return input:match("^%s*%?%s*(.-)%s*$") or input:match("^%s*？%s*(.-)%s*$")
end

-- 検索の picker の見出し。question は question_of の結果
-- ? で始まる間は rg で探さず一覧が空になるので、AI 検索の質問を入れていることと、Enter で探すことを見出しで知らせる
---@param label string
---@param question? string
---@return string
local function search_title(label, question)
  if question == nil then
    return "Claude 会話検索" .. label .. "  ?質問 → Enter で AI 検索"
  elseif question == "" then
    return "AI 検索" .. label .. "  質問を入力して Enter"
  else
    return "AI 検索" .. label .. "  Enter で「" .. question .. "」を探す"
  end
end

-- 検索の picker を閉じて、question で AI 検索の picker を開く。question が空なら通知だけする
---@param picker snacks.Picker
---@param question string
---@param scope ClaudeHistoryScope
local function open_ask(picker, question, scope)
  if question == "" then
    vim.notify("claude: AI に聞きたいことを入力してください(例: ?去年 dbt のテストで困った話)", vim.log.levels.INFO)
  else
    -- 閉じた直後に開くと、元のウィンドウへ戻るときに新しい picker も閉じられるので、vim.schedule で次のループまで待つ
    picker:close()
    vim.schedule(function() ask_picker(question, scope) end)
  end
end

-- 検索の picker を開く。本文のキャッシュは作り直してある前提
---@param scope ClaudeHistoryScope
local function search_picker(scope)
  local paths = text.paths(scope.sessions)
  local base = hit_picker_opts(scope.project_width)
  local ask_key = config.options.ask_key
  local label = grep.scope_label(scope.root)
  Snacks.picker(vim.tbl_extend("force", base, {
    title = search_title(label),
    live = true,
    supports_live = true,
    -- 新しい発言から並べる
    matcher = { sort_empty = true },
    sort = { fields = { "time:desc", "idx" } },
    finder = function(_, ctx)
      local query = ctx.filter.search
      local question = question_of(query)
      ctx.picker.title = search_title(label, question)
      ctx.picker:update_titles()
      -- AI 検索の質問を入力している間は rg で探さない
      return (query == "" or question) and {}
        or require("snacks.picker.source.proc").proc(
          ctx:opts({
            notify = false,
            cmd = "rg",
            args = grep.rg_args(query, paths),
            transform = function(item)
              local hit = grep.parse_hit(item.text, query, scope.by_id)
              return hit and vim.tbl_extend("force", item, hit, { text = hit.session.title .. " " .. hit.line }) or false
            end,
          }),
          ctx
        )
    end,
    -- 先頭が ? なら AI 検索に切り替え、そうでなければ選んだ会話を resume する
    confirm = function(picker, item)
      local question = question_of(picker.input:get())
      if question then
        open_ask(picker, question, scope)
      else
        base.confirm(picker, item)
      end
    end,
    win = ask_key and { input = { keys = { [ask_key] = { "ask", mode = { "n", "i" } } } } } or nil,
    actions = {
      -- ask_key で、入力中の文を質問にして AI 検索に切り替える。先頭の ? はあってもなくてもよい
      ask = function(picker)
        local input = picker.input:get()
        open_ask(picker, question_of(input) or vim.trim(input), scope)
      end,
    },
  }))
end

-- 会話を live grep する。入力のたびに本文のキャッシュを rg で探し、Enter で resume する
-- 先頭に ? を付けて Enter を押すと、残りの文を質問にして同じ範囲を AI 検索する。ask_key を設定すれば、そのキーでも AI 検索に切り替わる
---@param opts? { root?: string }
function M.search(opts)
  grep.with_sessions(opts and opts.root, function(scope)
    text.update(scope.sessions, function() search_picker(scope) end)
  end)
end

return M
