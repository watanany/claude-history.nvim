-- 発言の本文のキャッシュ(picker には依存しない)。live grep と AI 検索は、transcript ではなくここを探す
-- transcript はツールの結果を含めて GB 単位になる。直接 rg すると遅く、ツールの結果や JSON のエスケープ(\" など)にも当たる
-- そこで発言の本文だけを、会話ごとに「role \t uuid \t time \t 本文の 1 行」の形で書き出しておく(全部で数 MB)
local transcript = require("claude-term.transcript")
local util = require("claude-history.util")

local M = {}

local dir = vim.fs.joinpath(vim.fn.stdpath("cache"), "claude-history", "text")

-- 会話の本文のキャッシュのパス
---@param id string
---@return string
function M.path(id)
  return vim.fs.joinpath(dir, id .. ".txt")
end

---@param sessions ClaudeSession[]
---@return string[]
function M.paths(sessions)
  return vim.iter(sessions):map(function(s) return M.path(s.id) end):totable()
end

---@param path string
---@return integer
local function mtime_ns(path)
  local stat = vim.uv.fs_stat(path)
  return stat and (stat.mtime.sec * 1e9 + stat.mtime.nsec) or -1
end

-- transcript より古いキャッシュだけを作り直し、終わったら done を呼ぶ
---@param sessions ClaudeSession[]
---@param done fun()
function M.update(sessions, done)
  local stale = vim.tbl_filter(function(s) return mtime_ns(M.path(s.id)) < mtime_ns(s.path) end, sessions)
  if #stale == 0 then
    done()
  else
    vim.fn.mkdir(dir, "p")
    util.spawn(
      vim.list_extend({ "rg", "--no-heading", "--with-filename", "--null", transcript.message_pattern },
        vim.iter(stale):map(function(s) return s.path end):totable()),
      {},
      function(res)
        local by_path = vim.iter(vim.split(res.stdout or "", "\n", { trimempty = true })):fold({}, function(acc, l)
          local path, json = l:match("^(.-)%z(.*)$")
          local m = path and transcript.parse_message(json)
          local rows = m and vim.iter(vim.split(m.text, "\n", { plain = true }))
            :filter(function(line) return vim.trim(line) ~= "" end)
            :map(function(line) return ("%s\t%s\t%s\t%s"):format(m.role, m.uuids[1] or "", m.time, line) end)
            :totable()
          acc[path or ""] = vim.list_extend(acc[path or ""] or {}, rows or {})
          return acc
        end)
        -- 発言がなくても書いて、次から作り直さないようにする
        vim.iter(stale):each(function(s) vim.fn.writefile(by_path[s.path] or {}, M.path(s.id)) end)
        done()
      end
    )
  end
end

---@class ClaudeTextRow
---@field session ClaudeSession
---@field uuid string
---@field role "user"|"assistant"
---@field time string
---@field line string 本文の 1 行

-- キャッシュを rg --with-filename --null で探した出力の 1 行を読む。by_id にない会話なら nil
---@param text string
---@param by_id table<string, ClaudeSession>
---@return ClaudeTextRow?
function M.parse_row(text, by_id)
  local path, role, uuid, time, line = text:match("^(.-)%z(%a+)\t([^\t]*)\t([^\t]*)\t(.*)$")
  local s = path and by_id[path:match("([^/]+)%.txt$") or ""]
  return s and { session = s, uuid = uuid, role = role, time = time, line = vim.trim(line) } or nil
end

return M
