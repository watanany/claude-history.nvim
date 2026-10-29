# claude-history.nvim

Claude Code の会話を検索して resume するプラグイン。

## 機能

- **live grep**
  - 全プロジェクト、または今のプロジェクトの会話の本文を、入力のたびに `rg` で探す
  - ヒットした発言の前後をプレビューに出す
  - Enter で、その会話を resume する
- **AI 検索**
  - 検索の picker で、先頭に `?`(全角の `？` でもよい)を付けて Enter を押すと、残りの文を質問にして探す
    - 例: `?去年 dbt のテストで困った話`
    - `?` で始まる間は `rg` で探さず、見出しが「AI 検索」に変わる
  - 言い換えや、語を覚えていない会話を探すのに使う
  - 次の順で探す
    1. `model` で指定したモデル(既定は haiku)が検索語を考える
    2. 発言の本文を BM25 で点数付けする
    3. 同じモデルが上位を並べ替える
- **プレビュー**
  - 会話の最新の発言を描く関数がある
  - claude-term.nvim の一覧(`vim.ui.select`)のプレビューにも使える

## 必要なもの

- claude-term.nvim(一覧と resume)
- snacks.nvim(picker)
- `claude`(Claude Code)、`rg`

### Snacks が必要な理由

- live grep と、入力に応じて Enter の動きを変えること(先頭の `?`)は、`vim.ui.select` ではできない
- picker に依存しない部分は分けてある
  - `grep.lua`、`ask.lua`、`preview.lua` に置いている
  - Snacks を `require` しない
- Snacks とつなぐ部分は `pickers/snacks.lua` だけにある
- 別の picker に対応するときは、`pickers/` にファイルを足せばよい

## セットアップ(lazy.nvim)

```lua
{
  "watanany/claude-history.nvim",
  dependencies = { "folke/snacks.nvim", "watanany/claude-term.nvim" },
  opts = {},
  keys = {
    { "<Leader>as", function() require("claude-history").search({ root = vim.fs.root(0, ".git") or vim.fn.getcwd() }) end, desc = "Claude 会話検索(プロジェクト)" },
    { "<Leader>aS", function() require("claude-history").search() end, desc = "Claude 会話検索(全部)" },
  },
}
```

### オプション

| キー      | 説明                                                         | 既定値    |
| --------- | ------------------------------------------------------------ | --------- |
| `ask_key` | 検索の picker の中で、AI 検索に切り替えるキー(先頭の `?` と同じ動き) | `nil`     |
| `model`   | AI 検索で使うモデル(`claude -p --model` に渡す)            | `"haiku"` |

`ask_key` に Alt のキー(`<M-a>` など)を使うときは、ターミナルが Option を Alt として送る設定になっている必要がある。macOS の Ghostty なら `macos-option-as-alt`、kitty なら `macos_option_as_alt`。

live grep と AI 検索は、発言の本文を `stdpath("cache")/claude-history/text` に書き出しておき、そこを探す。transcript はツールの結果を含めて大きく、直接探すと遅いうえ、ツールの結果や JSON のエスケープにも当たるため。キャッシュは picker を開く前に、transcript が更新された会話の分だけ作り直す。初回は数秒かかる。

## claude-term.nvim の一覧にプレビューを付ける

Snacks の ui_select で、kind ごとにプレビューを付ける。

```lua
{
  "folke/snacks.nvim",
  opts = {
    picker = {
      sources = {
        select = {
          kinds = {
            claude_session = {
              layout = { preset = "telescope" },
              preview = function(ctx)
                ctx.preview:reset()
                ctx.preview:set_title(ctx.item.item.title)
                require("claude-history.preview").render_preview(ctx.buf, ctx.win, ctx.item.item)
                ctx.preview:highlight({ ft = "markdown" })
              end,
            },
          },
        },
      },
    },
  },
}
```
