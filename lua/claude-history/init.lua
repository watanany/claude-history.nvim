-- Claude Code の会話を検索して resume する。live grep と AI 検索
-- 一覧と resume は claude-term.nvim を使う。picker は Snacks.picker を使う(live grep と、入力に応じて Enter の動きを変えることは vim.ui.select ではできないため)
local config = require("claude-history.config")

local M = {}

---@param opts? ClaudeHistorySetupOptions
function M.setup(opts)
  config.options = vim.tbl_deep_extend("force", vim.deepcopy(config.defaults), opts or {})
end

-- 会話を live grep する。root を渡すと、その中(サブディレクトリを含む)で動いた会話だけを探す
---@param opts? { root?: string }
function M.search(opts)
  require("claude-history.pickers.snacks").search(opts)
end

return M
