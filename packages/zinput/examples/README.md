# zinput examples

One runnable example per input type. Each is a self-contained `main` that wires
a stdin reader / stdout writer (see `common.zig`) and drives a single prompt.

Run one (they're interactive, so use a real terminal):

```sh
zig build run-select        # or: text, confirm, multi_select,
                            #     password, search, number, editor
```

Build all of them at once:

```sh
zig build examples          # binaries land in zig-out/bin/zinput-<name>
```

| Example         | Function            | Returns            |
| --------------- | ------------------- | ------------------ |
| `text`          | `zinput.text`       | entered string     |
| `confirm`       | `zinput.confirm`    | `bool`             |
| `select`        | `zinput.select`     | chosen index       |
| `multi_select`  | `zinput.multiSelect`| chosen indices     |
| `password`      | `zinput.password`   | masked string      |
| `search`        | `zinput.search`     | chosen index       |
| `number`        | `zinput.number`     | `i64`              |
| `editor`        | `zinput.editor`     | text from `$EDITOR`|

All prompts fall back to plain line-based input when stdin isn't a TTY, so the
examples also work when piped (e.g. `printf '2\n' | zig-out/bin/zinput-select`).
