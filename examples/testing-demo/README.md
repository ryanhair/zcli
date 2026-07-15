# testing-demo

A minimal `greeter` CLI whose entire purpose is to show the `zcli-testing`
harness used directly inside a real example app, not just wired in silently by
the scaffolding:

- `src/commands/greet.zig` has `test` blocks that call the **unit tier**
  (`testing.runCommand`) explicitly — the same idiom `zcli init` scaffolds,
  written out so it's visible.
- `src/integration_test.zig` is a dedicated integration test file (this
  project's counterpart to `packages/core/src/build_integration_test.zig`)
  using the **subprocess/snapshot tier** (`testing.runSubprocess` +
  `testing.expectSnapshot`) against the actual compiled `./zig-out/bin/greeter`
  binary — the full stack, not just `execute()` in isolation.

```
zig build test
```

runs both tiers (`build.zig` wires the integration test's `Run` step to depend
on the install step, so the binary exists before it's driven).

See [`packages/testing/README.md`](../../packages/testing/README.md) and its
`examples/` for the complete tour of all three testing tiers in isolation.
