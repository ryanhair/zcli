# A public subprocess runner with safe defaults

Status: accepted

Every real CLI shells out. Before this, zcli had the shape of the answer three
times over — `packages/core/src/plugins/zcli_secrets/subprocess.zig`,
`packages/testing/src/runner.zig`, and `packages/testing/src/e2e.zig` — each
solving a subset, none public, and the strongest one locked inside a plugin.
`zcli.process` promotes one correct implementation to public API, in the spirit
of `zcli.http`.

`std.process.run` (0.16) is close but structurally cannot serve: it hard-codes
`.stdin = .ignore`, so it cannot feed a child at all — which is the point for
`gh api --input -`, `kubectl apply -f -`, `ssh host 'cat > file'`, and every
secret-on-stdin pattern. It has no sensitivity model, and its overflow behaviour
(`error.StreamTooLong`, everything captured discarded) is not configurable.

This ADR records the calls that are hard to reverse. The mechanism — how the
loop drains, probes, and tears down — is documented in `process.zig` itself,
because it will change as `std.Io` grows; these are the decisions that would be
breaking to revisit.

## `Env.inherit` is the default, and it is not a security control

The child receives the parent's whole environment unless the caller says
otherwise. Threading `environ` through `Runner` buys **provenance** (you can see
and test what the child gets) and **hermeticity** (a test supplies a map instead
of leaking the developer's shell). It does **not** buy least privilege, and the
docs say so plainly rather than dressing it up.

Inheriting is still right, for four reasons:

1. **The threat model is not confinement.** We are not sandboxing `gh`; the user
   installed it and asked for it. The failure this component genuinely prevents
   is *the environment choosing the binary*, and that is `Program`'s job.
2. **ADR-0010 already made this call in the harder case.** `zcli_secrets` ships a
   decrypted credential to `pass`/`secret-tool` and still forwards the
   environment whole, because a trimmed environment must carry PATH anyway for a
   shell-script helper, and trimming breaks pinentry, the session bus,
   `GNUPGHOME`, and locale. A stricter default for the general runner than for
   the secrets path would be incoherent.
3. **Any allowlist we shipped would be wrong.** `gh` wants `GH_*`, `GITHUB_*`,
   `HOME`, `XDG_CONFIG_HOME`, `PATH`, `HTTPS_PROXY`, `TERM`; `ssh` wants
   `SSH_AUTH_SOCK`, `SSH_ASKPASS`, `DISPLAY`; `kubectl` wants `KUBECONFIG` and
   cloud credentials. Every list breaks Nix, Homebrew, corporate proxies, or
   enterprise auth plugins, and the failure mode is "works in my shell, not in
   your CLI".
4. **A list that must include PATH and HOME has already conceded the interesting
   parts.** Failing closed there would be theatre.

`.allow`/`.deny`/`.replace` are one line away for callers who do want least
privilege, and the guide carries the recipe.

## `Program` has no implicit-PATH variant

`std.process.spawn` documents that a bare `argv[0]` "is resolved into a file path
based on PATH from the **parent** environment" — not `environ_map`. So an
implicit variant would be an ambient lookup in disguise: the environment policy
could not reach it, and neither could a test. `.search_path` covers the same
ergonomics explicitly, and uses the PATH the *child* will see.

## Resolution happens in the parent, to an absolute path

Every variant resolves to an absolute path before `std.process.spawn` is called.
This is what makes "the environment does not choose the binary" mechanical rather
than aspirational — `spawn` performs no PATH search for a path-shaped `argv[0]`
on POSIX or an absolute one on Windows.

The alternative would have been `std.process.spawnPath`, which is
`@panic("TODO processSpawnPath")` in all three 0.16 backends and therefore
unusable. That is a fact about today's `std`; the decision is not, because
resolving in the parent is also what lets the runner apply its own rules
(basename enforcement, relative-PATH-entry skipping, and the Windows extension
rules below) before anything is executed.

**On Windows the rules are uniform across all four variants, `.path` included.**
`windowsCreateProcessPathExt` enumerates `app_name*` in the target directory and
deliberately does not stop at an exact match, so handing it an absolute
`C:\d\foo` whose spawn fails lets it execute `C:\d\foo.cmd` instead. Three rules
close that: a resolved target must carry an explicit supported extension
(`error.UnsupportedProgramExtension`), extensions are classified
ASCII-case-insensitively, and a target with a supported-extension sibling is
refused with `error.AmbiguousProgram` regardless of `allow_windows_script`. An
earlier draft offered `.path` as a bypass; that was wrong, because std's fallback
keys off *what is in the directory*, not off how the runner named the file.

The cost is explicit: on Windows, `.{ .path = "C:\\tools\\gh" }` must be written
`"C:\\tools\\gh.exe"`. POSIX is unaffected.

The sibling check is a check-then-spawn, so it is TOCTOU by construction — the
same shape, and the same honest caveat, as `zcli_secrets`'s `resolveHelper`. It
is a check-time defence, not a guarantee.

## `.bat`/`.cmd` are refused unless opted into

`cmd.exe` re-parses its own command line, so argument quoting for batch targets
is a known injection class (the BatBadBunny/CVE-2024-24576 family); std's own
backend carries a dedicated `error.InvalidBatchScriptArg` for its pitfalls.
Refusal is the default, `Options.allow_windows_script` is the opt-in. The cost is
one explicit flag for a Windows-only tool shipped as a `.cmd` shim.

## Refuse rather than degrade when the `Io` cannot provide concurrency

The drains use `Batch.awaitConcurrent`, which *requires* the implementation to
run operations concurrently, rather than `awaitAsync`, which merely permits it —
so an `Io` that would serialize (and therefore deadlock) fails loudly with
`error.ConcurrencyUnavailable` instead of hanging. An earlier draft proposed an
inline small-payload fallback; it was both mis-tuned (the bound equalled the
Windows pipe quota exactly rather than sitting below it) and a hidden deadlock
risk. The real runtime `Io` always has concurrency, so this costs nothing in
practice and keeps the deadlock-freedom claim unconditional rather than
qualified.

## Exclusive child-reaping is a documented precondition

The runner reaps its own children by polling and never calls `Child.wait` or
`Child.kill`, so there is exactly one reaper by construction. That is what makes
signalling race-free: a signal is only sent between a probe that returned "still
running" and the next probe, on the one task that owns the run. It holds only if
the embedding process reaps its own children exclusively — no `SIGCHLD` set to
`SIG_IGN`, no `SA_NOCLDWAIT`, no wildcard `waitpid(-1)` reaper.

zcli installs none of these and a command owns its process, so the intended
consumer satisfies this for free. It is documented because `Runner` is public API
and an embedding application may be less tidy.

Where the OS provides a stable identity the runner takes it: Windows signals
through the process `HANDLE` (inherently race-free — the handle keeps the
identity valid after exit), and Linux through a `pidfd` acquired immediately
after spawn. The pidfd removes the *long* window — acquisition happens right
after spawn while the signal may come minutes later — but not the requirement,
because `pidfd_open` is itself pid-keyed and only `CLONE_PIDFD` at spawn would
close the remaining gap. `std.process.spawn` exposes no way to ask for that. On
macOS/BSD there is only the pid, and the residual risk is stated rather than
hidden.

When the precondition *is* violated, the runner reports
`error.ChildReapedElsewhere` with `phase = .wait`, sends no further signal, and
returns rather than hanging — a deliberately weakened promise, because the
alternative is signalling into a pid we no longer own.

## The default timeout is `.none`

The closest call here. A framework default of "hangs forever" is exactly the
footgun this component exists to remove — but subprocesses legitimately run for
minutes (`git clone`, `docker build`, `kubectl wait`), and aborting one mid-flight
can leave remote state worse than waiting. Two things tip it: the orphan linger
removes the most common *silent* hang (a grandchild holding an output pipe after
the child exits), and a timeout costs a hard concurrency requirement. The option
is prominent in the guide and set in the worked example.

## The sensitivity model covers stdin and captured output only

`EnvEntry` has no `sensitive` flag, because it could not keep the promise:
`std.process.spawn` re-serializes the entire environment into its own arena
(`createPosixBlock` / `createWindowsBlock`) and frees it with `arena.deinit()`,
which does not zero. There is no hook. An earlier draft offered the flag, and it
would have been a lie. The docs carry the full "not guaranteed" list —
environment values, child memory, kernel pipe buffers, swap, core dumps, arena
pages — verbatim, because a scrubbing promise is only useful if its edges are
stated.

## `packages/testing` does **not** migrate

An earlier draft proposed folding `runSubprocess` onto core and re-exporting its
`Termination`. Both were wrong:

- That tier is **deliberately std-only** — `packages/testing/build.zig` says so
  in a comment, and only the in-process unit-testing tier depends on zcli core.
  Routing the subprocess tier through core would invert that.
- Its public `RunOptions.env` is `?*const Environ.Map` defaulting to `null`
  (meaning "inherit the harness's environment"), whereas `Runner` requires a map.
  A wrapper could not preserve the published signature.
- Its `Termination` is a *different type* (`signaled: u8`, payloadless
  `unknown`); re-exporting core's four-case union would be a breaking change to a
  shipped package.

The duplication is real and accepted. If the two are ever unified it should be a
deliberate breaking change to `zcli_testing`, not a side effect of adding this
module.

## What is deferred

- **Descendants are not chased on abort.** An aborted run kills the direct child
  only; a daemonizing grandchild survives, and one holding stdin or stdout
  affects teardown. `SpawnOptions.pgid` would let us signal the whole group, but
  it changes terminal signal delivery for `.inherit` children (Ctrl-C stops
  reaching them), so it cannot be the unconditional default. An explicit
  `Options.isolate_process_group` can be added later. The *normal*-path stall is
  already handled by the orphan linger.
- **No `resource_usage_statistics`.** It is `null` on some platforms, which
  invites callers to depend on it.
- **Polling, not notification.** Exit detection is a backing-off poll (1 ms
  doubling to 250 ms) because there is no portable way to put a child-exit event
  into the batch: a self-pipe would need an `ASYNCHRONOUS` handle on Windows and
  `windowsCreatePipe` is private to `Io.Threaded`. Worth revisiting if `std`
  exposes it, or if `Io` ever grows a child-exit operation — which would let the
  exit join the batch directly and retire the polling altogether.
