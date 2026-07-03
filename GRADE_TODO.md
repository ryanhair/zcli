# Repo Grade — Fix Tracker

Findings from the full-repo audit (2026-07-02): security, architecture, structure, Zig patterns, testing/CI, docs.
Working through these one PR at a time, in order. Each item is scoped to be one reviewable PR.

Grades at audit time: Architecture A-, Docs/DX A-, Testing B+, Security B, Zig patterns B-, Structure C+.

## Priority items

- [x] 1. **CI test wiring** — ztheme's 44 tests are missing from the root test aggregator (`build.zig` `test_projects`), and projects/zcli's 81 unit tests never run in CI (only `e2e` runs). Add both to the root `zig build test` aggregation.
- [x] 2. **zig fmt** — 22 files fail `zig fmt --check` (incl. `packages/core/src/registry.zig`, `projects/zcli/src/commands/release.zig`). Run `zig fmt`, add a `fmt --check` step to CI.
- [x] 3. **HTTP redirect header leak** — the safe wrapper forwards caller headers (incl. `Authorization`) across cross-origin redirects for GETs (`packages/core/src/http.zig:115`, `:250-256`). Strip sensitive headers on cross-origin hops; add a loopback test (redirect to a second listener, assert auth header absent on hop 2).
- [x] 4. **install.sh fails open** — checksum verification silently skipped when `shasum` is missing (`install.sh:86-103`); failed `checksums.txt` download warns-and-continues. Fail closed: fall back to `sha256sum`, abort if neither exists or checksums can't be fetched.
- [x] 5. **Upgrade plugin temp-file TOCTOU** — downloads to predictable `.upgrade-<name>-0` in CWD (`packages/core/src/plugins/zcli_github_upgrade/plugin.zig:430-478`); symlink clobber risk. Download to a private per-invocation temp dir (same filesystem as the executable so the final rename stays atomic).
- [x] 6. **Upgrade plugin bypasses safe HTTP wrapper** — raw `std.http.Client` at `plugin.zig:238`, `:435`, `:489`; no timeout, so `onStartup` version check (`inform_out_of_date`) can hang the CLI indefinitely. Route through `zcli`'s `http.Client` or add explicit short timeouts; time-box the startup check.
- [x] 7. **Dormant compile bombs in core** — (a) `.Slice` should be `.slice` (`registry.zig:1350`, `:1390`); (b) broken `std.mem.join(&[_]u8{}, ...)` in duplicate-path `@compileError` branches (`registry.zig:421`, `:489`, `:505`); (c) comptime underflow for a zero-command registry (`registry.zig:1045-1062`, missing empty guard the plugin sort has); (d) `std.posix.getenv` (gone in 0.16) in the unused option-`env` feature (`options/parser.zig:200`) — remove or reimplement via threaded environ.
- [x] 8. **snapshot.zig is un-migrated 0.15 code exported as pub API** — `packages/testing/src/snapshot.zig` uses `std.fs.cwd()` / `getEnvVarOwned`; first downstream caller of `expectSnapshot` gets a compile error. Migrate to 0.16 IO.
- [x] 9. **vterm resize out-of-bounds** — `resize` reallocates `new_width × new_height` but never updates `scrollback_lines` (`packages/vterm/src/vterm.zig:362-386`), so post-resize scrolling indexes out of bounds; `buffer_start` never advances (circular buffer half-implemented). Also `eraseFromCursor`/`eraseToCursor` mix viewport vs buffer coordinates (`:683-698`).
- [x] 10. **Required options read `undefined`** — non-bool, non-optional, non-defaulted Options fields are initialized to `undefined` and read if the flag is absent (`options/parser.zig:174-177`, `command_parser.zig:240-243`). Enforce defaults/optionality at comptime in `validateMeta`, or implement required-option errors.
- [x] 11. **`context.exit()` drops buffered output** — `registry.zig:392-394`, `zcli.zig:170-172` discard `self` and call `std.process.exit` without flushing the framework-owned writers. Flush `self.io` before exiting.

## Security — remaining

- [x] 12. **testBinary is a no-op** — prints "Testing new binary…" but never executes it (`plugin.zig:583-590`). Actually spawn the temp binary with `--version` and check exit code, or remove the step and message.
- [x] 13. **Checksum line matching is a loose substring** — `parseExpectedChecksum` uses `indexOf` on the whole line (`plugin.zig:550-560`), so `myapp-x86_64-linux-debug` can match before `myapp-x86_64-linux`. Split into digest/filename columns and compare exactly.
- [x] 14. **`sh -c` in release.zig** — `getReleaseNotes` interpolates tag names into a shell string (`projects/zcli/src/commands/release.zig:633-640`); every other call uses argv arrays. Drop the shell, pass the tag range as one argv element.
- [x] 15. **Resource limits partially enforced** — only `checkOptionCount`/`checkOptionNameLength` are wired; `checkArraySize`, `max_argument_count`, `checkCommandDepth` unused (`packages/core/src/resource_limits.zig` vs `options/parser.zig`, `args.zig`). Wire them in or delete the unused fields; tighten `security_test.zig` to assert the caps that are enforced.
- [x] 16. **serde hash label mismatch** — *false alarm*: upstream v1.0.3 tag ships a zon still declaring version 1.0.1, so the `serde-1.0.1-…` hash IS correct for the v1.0.3 tarball. Explanatory comment (already in core's zon) copied to the root zon so it isn't "fixed" into a broken build.
- [x] 17. **No release signing (documented decision)** — integrity anchors solely on GitHub (checksums.txt from the same release). Consider minisign/cosign signing of checksums.txt; at minimum document the trust model in ADR-0002/0003.
- [x] 18. **Startup version check behavior** — document the outbound network call at `Config.inform_out_of_date`, and cache the last check with a min interval so it doesn't fire on every invocation.

## Zig patterns / correctness — remaining

- [ ] 19. **Dead diagnostic system** — `ZcliDiagnostic`/`formatDiagnostic` (`diagnostic_errors.zig`) never constructed or consumed; real error context goes through a test-suppressed `std.log` side channel invisible to `onError` plugins. Wire diagnostics through the pipeline (so help plugin can name the unknown option) or delete. Also fix `convertLongOptionError`/`convertShortOptionError` `anyerror` catch-alls (`options/parser.zig:286-305`).
- [ ] 20. **Option-parsing heuristics disagree** — three different "does this flag take a value" heuristics: `command_parser.zig:75-115`, `options/parser.zig`, `args.zig:findNextPositional` (`:240-257`). Unify on one source of truth (the comptime Options type).
- [ ] 21. **Global options half-implemented** — short options "assume boolean for now" (`registry.zig:916-917`); `convertValue` supports only bool/u16/u32/[]const u8 while `plugin_types.option()` accepts more (`registry.zig:951-960`). Support the full type set or reject unsupported types at declaration.
- [ ] 22. **`IO` two-phase init pointer-stability trap** — `finalize()` wires writers to in-struct buffers; any copy after finalize dangles (`zcli.zig:344-391`). Restructure to prevent misuse (heap/pin, or factory that returns a pointer).
- [ ] 23. **parseCommandLine leak on error path** — frees only the slice, not parsed option arrays, when `parseArgs` fails outside an arena (`command_parser.zig:128-132`); plus muddled belt-and-suspenders frees of arena memory in `Context.deinit`.
- [ ] 24. **errors.zig fossils** — discarded `allocator` params kept "for API compatibility" (`errors.zig:11`, `:33`, `:97`) contrary to the no-backward-compat rule; doc references a nonexistent "zcli-suggestions plugin"; `editDistance` silently caps at 62 chars with a 32KB stack matrix.
- [ ] 25. **zinput text input is byte-oriented** — `char: u8` echo/backspace per byte breaks multibyte UTF-8 (`packages/zinput/src/text.zig`), inconsistent with the grapheme-aware wrapping elsewhere in the stack.

## Structure / dead code

- [ ] 26. **Split `executeCommand`** — single ~584-line function (`registry.zig:962-1545`); regular-command and plugin-command paths are ~230 near-identical lines each (6 copies of the onError inline-for). Extract shared helpers.
- [ ] 27. **Context triplication** — the Context interface is defined three times (`registry.zig:278-396`, `zcli.zig:107-203`, `zcli.zig:264-341`); `getCommandDescription` copy-pasted verbatim in all three. Single source of truth.
- [ ] 28. **Split `add/command.zig`** (1,221 lines) — wizard prompt IO, declarative scaffold, source rendering, and ANSI paint helpers in one file. (Split plan already sketched: generate/declarative/wizard/command.)
- [ ] 29. **Legacy `build_utils.zig` cleanup** — 772-line doc-header + stale test grab-bag incl. a no-op `expect(true)` test (`:25-36`). Also `build_utils/main.zig` contains never-run tests asserting a generator signature that no longer exists (`:465`, `:547` vs `code_generation.zig:180-190`) — fix and wire them, or delete.
- [ ] 30. **plugin_system.zig dead apparatus** — ~850 of 1,014 lines are mocks/tests including a sandbox/capabilities concept that doesn't exist in the runtime (`build_utils/plugin_system.zig:659`). Trim to the ~160 lines of real build logic.
- [x] 31. **`scanLocalPlugins` unreachable / ADR-0006 dead** *(resolved by #41/#51: `generate()` honors `plugins_dir`, init wires it, discovery fixed)* — `generate()` hardcodes `.plugins_dir = null` (`build_utils/main.zig:215`), so convention plugin discovery is dead code while ADR-0006 says "accepted". Either implement (roadmap: `zcli add plugin`) or mark the ADR deferred and remove the dead path.
- [ ] 32. **Stale `terminal` dep in core's zon** — `packages/core/build.zig.zon` declares `.terminal` but core never uses it.
- [ ] 33. **Dead parser code** — `parseShortOptions` has zero callers (dead un-meta duplicate of `parseShortOptionsWithMeta`, `options/parser.zig:655+`); `expected_char` comptime block copy-pasted three times in one function (`:511`, `:546`, `:582`).
- [ ] 34. **core/build.zig test-wiring duplication** — same five `addImport` lines copy-pasted across four test loops with mis-indentation (`packages/core/build.zig:84-198`), plus a leftover "debug hanging" step (`:200-210`). Extract a helper.

## Build / CI / test — remaining

- [ ] 35. **Re-enable `build_integration_test.zig`** — disabled at `packages/core/build.zig:74` ("needs rework for 0.16 *Build-based discoverCommands").
- [ ] 36. **Orphaned example tests** — `packages/vterm/example/tests/cli_test.zig` (20 tests) and showcase command tests have test steps but root only builds examples (`build.zig:129-142`).
- [ ] 37. **e2e on macOS in CI** — the PTY harness works on macOS but the e2e job is ubuntu-only (`ci.yml:64-80`).
- [ ] 38. **release.yml uses deprecated setup-zig action** — `goto-bus-stop/setup-zig@v2` vs ci.yml's `mlugg/setup-zig@v2`.
- [ ] 39. **Root build shells out per package** — `addSystemCommand(&.{"zig"})` + `setCwd` forfeits shared cache/flag propagation; module wiring duplicated between root `build.zig:65-74` and `packages/core/build.zig:32-41`. Consider `b.dependency`-based aggregation.
- [ ] 40. **`generate()` config is `anytype`** — hand-rolled `@hasField` checks (`build_utils/main.zig:164-167`); use a typed config struct. Also `readVersionFromZon` string-scans the zon and build errors call `std.process.exit(1)` mid-build.
- [x] 43. **PTY harness deadlock (found during fix 11)** — `runInteractive` leaked the PTY master fd into the child (no CLOEXEC on `/dev/ptmx`), so closing the harness's master never delivered EIO to a child blocked writing into the full (4 KiB on macOS) PTY buffer; combined with a fixed 1s post-script drain before an unbounded `child.wait`, any child printing >4 KiB after its last prompt (e.g. `init` post-#41) hung the e2e suite forever. Fixed: CLOEXEC on master/slave/pipe fds, drain-until-HUP with the config deadline, SIGTERM on timeout.

## Docs — remaining

- [ ] 41. **Stale docs** — README.md:487 lists the removed "interactive" package; TODOS.md:59 leaves shipped HTTP client unchecked; `projects/zcli/build.zig:138` + `test/e2e.zig:8` reference gitignored `.context/e2e-test-plan.md`; ADR-0001 status still "proposed" though shipped.
- [ ] 42. **Missing per-package READMEs / CONTRIBUTING.md** — core, terminal, testing, zinput, zprogress have no README despite the root claiming all packages work standalone.
