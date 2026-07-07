# prompts examples

One runnable example per input type. Each is a self-contained `main` that wires
a stdin reader / stdout writer (see `common.zig`) and drives a single prompt.

Run one (they're interactive, so use a real terminal):

```sh
zig build run-select        # or: text, confirm, multi_select,
                            #     password, search, number, editor
```

Build all of them at once:

```sh
zig build examples          # binaries land in zig-out/bin/prompts-<name>
```

| Example         | Function            | Returns            |
| --------------- | ------------------- | ------------------ |
| `text`          | `prompts.text`       | entered string     |
| `confirm`       | `prompts.confirm`    | `bool`             |
| `select`        | `prompts.select`     | chosen index       |
| `multi_select`  | `prompts.multiSelect`| chosen indices     |
| `password`      | `prompts.password`   | masked string      |
| `search`        | `prompts.search`     | chosen index       |
| `number`        | `prompts.number`     | `i64`              |
| `editor`        | `prompts.editor`     | text from `$EDITOR`|

All prompts fall back to plain line-based input when stdin isn't a TTY, so the
examples also work when piped (e.g. `printf '2\n' | zig-out/bin/prompts-select`).
