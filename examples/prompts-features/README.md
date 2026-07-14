# prompts-features

A one-command `signup-cli` whose only job is to exercise the two prompt types
that had no example anywhere in the repo: `password` (masked input) and
`multi_select` (toggle-selection with space, confirm with enter). The other
prompt types — `text`, `select`, `number`, `confirm` — already have worked
examples in `examples/tasks`.

```
signup-cli signup
```

## Build

```
zig build
./zig-out/bin/signup-cli signup
```
