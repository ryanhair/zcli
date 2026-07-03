# repostat — a `zcli.http` example

A tiny CLI that prints stats for a public GitHub repository:

```
$ repostat repo ziglang/zig
ziglang/zig
  General-purpose programming language and toolchain...
  ★ 35000 stars  ·  Zig
  https://github.com/ziglang/zig
```

It's a **canonical example** (ADR-0004): a compiled, CI-checked teaching artifact
for one idiom — calling an HTTP API from a command with `zcli.http`. See
[`src/commands/repo.zig`](src/commands/repo.zig).

What it demonstrates:

- **`zcli.http.Client`** with safe defaults (TLS verification, a request timeout,
  a bounded response body) — no boilerplate to get them.
- **Request headers** via `client.request(.GET, url, .{ .headers = ... })`.
- **Typed JSON** with `Response.json(T, ...)` — the `Repo` struct models only the
  fields it renders; unknown fields are ignored.
- **The arena-per-command allocator** (ADR-0001): nothing here frees memory by
  hand; it's all reclaimed when the command returns.
- **Plain-language errors** to stderr for the failure paths (bad slug, non-200,
  unparseable body).

Run it:

```
zig build run -- repo ryanhair/zcli
```
