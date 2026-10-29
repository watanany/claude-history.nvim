-- setup のオプション
local M = {}

-- setup に渡すオプション。どれも省略でき、省いたものは既定値になる
---@class ClaudeHistorySetupOptions
---@field ask_key? string 検索の picker の中で、入力中の文で AI 検索に切り替えるキー。既定では割り当てない(先頭に ? を付けて Enter で切り替わる)
---@field model? string AI 検索で検索語を考え、結果を並べ替えるモデル(claude -p --model に渡す)

-- 既定値で埋めたあとのオプション
---@class ClaudeHistoryOptions : ClaudeHistorySetupOptions
---@field model string

---@type ClaudeHistoryOptions
M.defaults = {
  ask_key = nil,
  model = "haiku",
}

---@type ClaudeHistoryOptions
M.options = vim.deepcopy(M.defaults)

return M
