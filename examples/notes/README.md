# notes

A tiny note keeper built with [zcli](../../README.md) — the canonical example
for **saving and loading data in a JSON file**, and for **sharing a helper
module across commands**.

```
notes add greeting "Hello, there!"
notes add todo "Buy milk"
notes list          # greeting, todo
notes show greeting # Hello, there!
notes log           # add greeting, add todo
```

Data is persisted to `notes.json` in the current directory, and every change is
also recorded in an append-only `notes.log`.

## What it demonstrates

- **`src/store.zig`** — load/save a typed struct as JSON with `std.json`:
  `parseFromSlice` in, `std.json.fmt` out. No hand-written parsing or string
  building. This file is embedded verbatim into `zcli guide storage`.
- **`src/log.zig`** — the other storage shape: an append-only log that several
  processes can read and append to at once. Shared lock to read, exclusive lock
  to append, one flushed record per append, bounded reads, and a torn trailing
  record repaired rather than propagated (reader and writer draw the corruption
  line in the same place). Its own tests race appending threads and replay a
  half-written final record; `src/log_multiprocess_test.zig` repeats both with
  real child processes (`src/log_appender.zig`, built but never installed),
  because an advisory lock's owner is a process, not a thread. `build.zig` hangs
  both test binaries on the same `test` step as the command tests. Embedded into
  `zcli guide storage`.
- **A shared module** — `store` and `log` are imported by the commands,
  registered once in `build.zig` as `shared_modules` entries and wired into both
  `generate()` and `addCommandTests()`. See `zcli guide sharing`.
- **The arena** — commands load into `context.allocator` and never free; the
  per-command arena reclaims it. See `zcli guide arena`.
- **A plugin** — `src/plugins/verbose.zig` (auto-discovered) adds a global
  `--verbose` flag via `plugin_id` + `ContextData` + `global_options` +
  `handleGlobalOption`. Embedded into `zcli guide plugins`.
