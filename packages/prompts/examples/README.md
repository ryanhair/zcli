# prompts examples

One runnable example per input type. Each is a self-contained `main` that wires
a stdin reader / stdout writer (see `common.zig`) and drives a single prompt.
Every example is compiled by `zig build test`, so they can't bitrot.

Run one (they're interactive, so use a real terminal):

```sh
zig build run-select        # or: text, confirm, multi_select,
                            #     password, search, number, editor
```

Build all of them at once:

```sh
zig build examples          # binaries land in zig-out/bin/prompts-<name>
```

| Example        | Function              | Returns             | Options it shows                                   |
| -------------- | --------------------- | ------------------- | -------------------------------------------------- |
| `text`         | `prompts.text`        | entered string      | `default`, live `preview`, `interrupt_keys` (Esc)  |
| `confirm`      | `prompts.confirm`     | `bool`              | `default` (drives `(Y/n)` hint), `interrupt_keys`  |
| `select`       | `prompts.select`      | chosen index        | custom `.theme`, `unicode`, `interrupt_keys` (Esc) |
| `multi_select` | `prompts.multiSelect` | chosen indices      | `defaults` (pre-checked), `unicode`                |
| `password`     | `prompts.password`    | masked string       | `mask`, call-site length validation + re-prompt    |
| `search`       | `prompts.search`      | chosen index        | case-insensitive substring filter, `unicode`       |
| `number`       | `prompts.number`      | `i64`               | `default`, `min`/`max` range (re-prompts)          |
| `editor`       | `prompts.editor`      | text from an editor | `editor_cmd` (from `$EDITOR`), `extension`, `io`   |

## Notes

- **Interrupt keys.** `text`, `confirm`, `select`, and `number` accept
  `interrupt_keys` — keys the prompt won't handle itself. Pressing one aborts
  the prompt with `error.Interrupted`, which the caller catches to mean "go
  back" / "cancel". The examples map Esc to that.
- **Theming.** Every prompt instance carries a `theme` (`ThemeContext`).
  `select.zig` overrides it with a custom accent colour; in a zcli command you'd
  pass `context.theme` instead, which also carries the detected terminal
  capabilities (colour depth, `NO_COLOR`).
- **Non-TTY fallback.** All prompts fall back to plain line-based input when
  stdin isn't a TTY, so the examples also work when piped
  (e.g. `printf '2\n' | zig-out/bin/prompts-select`). The live-only features
  (`preview`, custom cursor glyphs) are simply skipped in that mode.
- **EOF is an error, not an empty answer.** When stdin closes with nothing left
  to read (a closed pipe, `</dev/null`, or an exhausted redirect), every prompt
  returns `error.EndOfStream` instead of an empty entry. That keeps a closed
  stream distinguishable from a submitted blank line, so a re-prompt loop can
  break on it rather than spin forever — see `password.zig` for the idiom.
