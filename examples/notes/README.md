# notes

A tiny note keeper built with [zcli](../../README.md) — the canonical example
for **saving and loading data in a JSON file**, and for **sharing a helper
module across commands**.

```
notes add greeting "Hello, there!"
notes add todo "Buy milk"
notes list          # greeting, todo
notes show greeting # Hello, there!
```

Data is persisted to `notes.json` in the current directory.

## What it demonstrates

- **`src/store.zig`** — load/save a typed struct as JSON with `std.json`:
  `parseFromSlice` in, `std.json.fmt` out. No hand-written parsing or string
  building. This file is embedded verbatim into `zcli guide storage`.
- **A shared module** — `store` is imported by all three commands, registered
  once in `build.zig` as a `shared_modules` entry and wired into both
  `generate()` and `addCommandTests()`. See `zcli guide sharing`.
- **The arena** — commands load into `context.allocator` and never free; the
  per-command arena reclaims it. See `zcli guide arena`.
