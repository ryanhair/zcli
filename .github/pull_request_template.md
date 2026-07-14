## What & why

<!-- One or two sentences: what changed, and why. Keep the PR to one logical change. -->

## Testing

- [ ] `zig build test` passes
- [ ] If this touches the build system, `zig build build-examples` still passes (examples are drift detectors — update them in the same PR if they break)
- [ ] If this changes prompt/render/help behavior, `zig build e2e` passes
- [ ] Added or updated tests covering the change

## Docs

- [ ] Updated relevant docs under `docs/` (or the scaffolding templates in `projects/zcli/src/commands/init.zig`) if user-facing behavior changed
- [ ] Added an ADR under `docs/adr/` if this is a significant design decision
