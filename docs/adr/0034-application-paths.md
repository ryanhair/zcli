# Platform-standard application paths resolved from the threaded environ

Status: accepted

Every CLI has to answer one question — *where does this app put its config,
cache, and data on this platform?* — and zcli was answering it in three places
with three different answers. `zcli_config` read `%APPDATA%` then
`%USERPROFILE%\.config`; `zcli_github_upgrade` hard-coded `~/Library/Caches` on
macOS and ignored `XDG_CACHE_HOME` there entirely; `zcli_completions` joined
with `/` even on Windows and ignored every variable the shells it installs for
actually honour. None of them honoured the XDG rule that a relative or empty
value must be ignored, and two of them disagreed with each other on macOS.

This ADR records the decision to answer it once, in a public `zcli.Paths`, from
the **explicitly threaded `environ`**.

## Why this is not a convenience wrapper

Three facts forced a real type rather than a helper function:

1. **`std.fs.getAppDataDir` no longer exists in Zig 0.16**, and the pre-0.16
   version used ambient `getenv` — which violates the repo's explicit-environ
   rule (ADR-0001's threading discipline) and pulls libc into a stack kept
   deliberately libc-free so the terminal packages build against static musl.
2. **`std.fs.path.join` and `std.fs.path.dirname` dispatch on the host.** A
   resolver that must be able to emit Windows paths while running on macOS —
   which is what makes the whole matrix testable without cross-compilation —
   cannot use either.
3. **`std.fs.path.isAbsoluteWindows` is not a safe "can I append to this?"
   test.** It accepts `\foo` (rooted on the *current drive*, which is process
   state), the `\\?\` and `\\.\` device namespaces, and bare `\\server` — whose
   disk designator swallows the entire string, so appending `{app}` yields
   `\\server\myapp` and the app name silently becomes the **share** name.

## Decision 1 — two axes, not one platform knob

`Paths` carries `convention` and `syntax` as separate **runtime** fields:

- **`convention`** — which environment variables and fallback tails describe the
  location. A *policy*. A tool's own contract may pin it: bash-completion is
  XDG-rooted wherever it runs.
- **`syntax`** — separators, absoluteness rules, `dirname`. A property of the
  *filesystem being addressed*, so anything doing I/O must use the host's.

Collapsing these into one "platform" enum is the mistake that makes shell
completions unimplementable: installing a bash completion on Windows needs XDG
*policy* with native Windows *syntax*. Keeping them separate also means the
entire resolution matrix is a pure string function of two fields, so all
`{3 kinds} × {3 conventions} × {2 syntaxes}` cells are asserted with exact
expected strings **on every host** — no cross-compilation, no CI matrix.

Every `ensure*` method requires `syntax == Syntax.host`, else
`error.ForeignSyntax`. The guard is on **syntax, not convention**, which is
exactly what lets a caller override the policy while still doing ordinary host
I/O.

## Decision 2 — the locations

| | `.windows` | `.macos` | `.xdg` |
|---|---|---|---|
| config | `%APPDATA%` | `$XDG_CONFIG_HOME` → `$HOME/.config` | `$XDG_CONFIG_HOME` → `$HOME/.config` |
| data | `%LOCALAPPDATA%` | `$XDG_DATA_HOME` → `$HOME/.local/share` | `$XDG_DATA_HOME` → `$HOME/.local/share` |
| cache | `%LOCALAPPDATA%` | `$XDG_CACHE_HOME` → **`$HOME/Library/Caches`** | `$XDG_CACHE_HOME` → `$HOME/.cache` |
| app segment | config → `{app}`, data → `{app}\data`, cache → `{app}\cache` | `{app}` | `{app}` |

**macOS uses XDG for config and data.** Stated plainly: this is a
CLI-ecosystem-compatibility policy, and Apple documents otherwise.
`~/Library/Application Support` is the convention for *bundled applications* and
is hostile in a terminal — a space in the path, deep to type, awkward to
tab-complete — while `gh`, `git`, `aws`, `kubectl`, `docker`, `cargo` and
`rustup` all put config in a home dotdir. The honest cost is that this is **not**
migration-free: a macOS user with `XDG_CACHE_HOME` set has their upgrade cache
move, because the old code ignored that variable entirely.

**macOS cache follows Apple.** `~/Library/Caches` is different in kind: macOS
excludes it from Time Machine and points its storage-management tooling at it for
reclamation. Putting a purgeable cache there is a functional property, not a
stylistic one. Homebrew and Go do the same.

**Windows data is local, not roaming.** `%APPDATA%` roams with the profile;
`%LOCALAPPDATA%` does not. Small hand-authored config should roam; bulk CLI data
(toolchains, indexes, sqlite files) should not, because roaming profiles are
size-constrained and administrators police them. Config stays at bare
`%APPDATA%\{app}` — zero migration for existing apps, and no `config\config.json`.
The `\data` and `\cache` leaves exist only because those two kinds share
`%LOCALAPPDATA%` and would otherwise collide.

## Decision 3 — error, never guess

`base()` returns a typed error rather than inventing a location.

A guess writes user data somewhere that is not the user's. With `HOME` unset — a
systemd unit, a scratch container, a CI runner, a `su` without `-`, a cron job —
a `"/home/user"`-style literal lands in someone else's tree, and a bare relative
path scatters files into whatever the working directory happens to be. For
`config` or `data`, which can hold credentials, that is a security bug.

The same argument retires the Windows `%USERPROFILE%\AppData\Roaming`
derivation: `FOLDERID_RoamingAppData` and `FOLDERID_LocalAppData` **can be
redirected** by group policy or roaming-profile configuration, and in exactly
those managed environments, writing to the un-redirected literal is the failure
that scatters data outside the profile. The only non-guessing recovery —
`getpwuid`, `SHGetKnownFolderPath` — is ambient OS state this design exists to
avoid, and the former is libc.

The degradation policy belongs to the caller and genuinely differs: the upgrade
plugin wants "no cache → probe every run", the config plugin wants "no user
config dir → skip that tier silently", and a command persisting an auth token
wants to fail loudly. A framework that picked one would be wrong for the other
two.

Errors: `HomeNotFound`, `HomeNotAbsolute` (whose diagnostic must enumerate the
accepted forms), `HomeMalformed`, `InvalidAppName`, `InvalidSubPath`, plus
`ForeignSyntax` and `PathNotFullyQualified` on the `ensure*` family.

### The override/terminal asymmetry

Deliberate, and directly tested:

- **An optional override (`XDG_*`) that is invalid is IGNORED**, and resolution
  falls through to the `$HOME`-relative default. Empty, relative, control-bearing
  or (under `.windows` syntax) invalid WTF-8 are all "invalid" in the XDG spec's
  sense, and its prescribed disposition is to use the default. None is an error.
- **A terminal source (`HOME`, `%APPDATA%`, `%LOCALAPPDATA%`) that is invalid is
  FATAL.** There is no second-choice location to fall through to.

Erroring on the low-priority input while falling back on the terminal one would
be exactly backwards.

## Decision 4 — one segment predicate, uniform on every platform

`Paths.isValidSegment` rejects a component that is empty; composed solely of `.`;
contains any of `< > : " / \ | ? *`; contains a control byte; has a leading or
trailing ASCII space; ends in `.`; or is not valid WTF-8.

The all-dots, trailing-dot and trailing-space rules close a real traversal:
**Win32 strips trailing periods and spaces from a component before the path
reaches the filesystem**, so `".. "`, `"..."` or `".. . "` would pass a naive
`!= ".."` check and then *become* `".."` during I/O. Checking uniformly on every
syntax means a `.posix` resolution can never emit a string that becomes a
traversal when later handed to a Win32 API. The WTF-8 rule exists because Zig's
Windows filesystem APIs specify `sub_path` as WTF-8 and transcode internally;
invalid WTF-8 is a malformed argument, not an unusual filename.

The cost is accepted: `p.file(.data, &.{"12:00.log"})` errors on Linux, where
that name is legal. One rule, portable output by construction, and such names are
nearly always a mistake in CLI-generated files.

**`registry/builder.zig` calls the same predicate at compile time.** The charset
check stays, because it is stricter in a *different* direction (it also rejects
shell metacharacters, since `app_name` is interpolated unescaped into generated
completion scripts). Containment then holds **by construction** —
registry-accepted ⊆ charset ∩ `isValidSegment` — rather than by inspection, which
is what previously let `"foo."` compile cleanly and then fail every `Paths` call
at runtime.

`Syntax.isFullyQualified` accepts exactly two Windows forms: a drive path `X:\…`
(drive-*relative* `C:foo` rejected) and a complete UNC root `\\server\share`. One
parser answers both "may I append to this?" and "how much of this is root that
trailing-separator trimming must not eat?", so those cannot drift.

## Decision 5 — `ensureParent` is the guarded primitive

`ensureFile` is defined as `file()` followed by `ensureParent()`. Exposing
`ensureParent(io, raw_path)` publicly is what makes the guarded I/O API reachable
for paths that are *not* app-scoped: without it, a caller holding a
`resolve`-built destination has no way to reach the `ForeignSyntax` check and
must hand-roll `dirname` + `createDirPath` — straight around the guard the
convention/syntax split exists to enforce. Its two checks (host syntax, fully
qualified) make it safe for any argument.

Directories the family creates are **`0700` on POSIX** — these may hold tokens,
and `createDirPath`'s default of `0o777` masked by umask is typically
world-readable `0755`. This applies uniformly, including to non-app-scoped
ancestors such as `~/.local/share/bash-completion` and `~/.config/fish`: those
almost always already exist, and an existing directory's mode is **never**
changed. There is no retroactive `chmod` — silently altering permissions on a
user's existing directory is a surprising side effect.

### What is and is not guaranteed

**Lexical containment.** No `app_name` or `sub_path` can make the resolved string
denote a location outside `base(kind)`, including after Win32 normalization. It
does **not** buy filesystem containment: a symlink or junction anywhere in the
base chain redirects creation and any subsequent write. The trust assumption is
that the home directory belongs to the user — the same one `zcli_completions`
already states. Handle-relative no-follow creation would be the real fix; it has
no clean Windows reparse-point equivalent and is out of scope. **Docs must say
"cannot escape lexically", never "cannot escape."**

**Character and encoding portability, not filesystem acceptance.** `ensure*` can
still fail on a segment the predicate accepted. Documented and deliberately
unchecked: **Windows reserved device names** (`CON`, `NUL`, `aux.json` — checking
would falsely reject a legitimate POSIX `aux.json`, and the Windows failure mode
is a clear I/O error, not a silent traversal), length limits,
case-insensitivity collisions, and macOS Unicode normalization.

## Consolidation

- **`zcli_config`** — `userConfigDir` and its `allocated: *bool` protocol are
  deleted; discovery calls `p.dir(.config)` and treats a resolution error as "no
  user-level config", preserving today's silence.
- **`zcli_github_upgrade`** — the cache path becomes one `ensureFile` call,
  absorbing `writeLastCheck`'s ad-hoc `createDirPath`. The `null` means "no
  cache" contract is preserved by a `catch` at the call site.
- **`zcli_completions`** — destinations now follow the shells' own contracts:
  bash honours `$BASH_COMPLETION_USER_DIR` (first list entry, split by `:` under
  POSIX syntax and `;` under Windows syntax, because MSYS rewrites POSIX path
  *lists* for native children) then the XDG default; fish is XDG-pinned; zsh is
  `home()`-relative because `fpath` is user-configured; PowerShell uses the
  **host** convention. The instruction printers take the **resolved** path and
  shell-quote it per shell, instead of re-hard-coding literals that are wrong for
  anyone with those variables set.
- **`zcli_secrets` is deliberately NOT consolidated.** Both of its sites are
  allocation-free by construction (they format into a caller-owned
  `[max_path_bytes]u8`), neither is app-scoped, and the shared logic is three
  already-correct lines. Routing them through an allocating `home()` would regress
  a deliberate property to share nothing worth sharing. The issue asked for
  consolidation "where their semantics match"; these do not.

MSYS2/Cygwin convert path-like environment values for native children, so the
**ordinary Git Bash setup works**. When conversion is suppressed for a variable
(`MSYS2_ENV_CONV_EXCL`), `HOME=/c/Users/u` yields `HomeNotAbsolute` with a
diagnostic naming both remedies, rather than being translated: translation means
guessing at a mount table we cannot read, and a wrong guess installs where the
shell will never look — a silent failure instead of a loud one.

## Consequences

Breaking changes, all enumerated in `CHANGELOG.md`: a relative/empty/malformed
`HOME` now errors instead of silently producing a **CWD-relative** destination
across config, cache and completions alike; the Windows `%USERPROFILE%\.config`
fallback is gone; invalid `XDG_*` is ignored and invalid `%APPDATA%` errors; the
upgrade cache moves on all three platforms for some populations; bash/fish/
PowerShell completion destinations move; and an `app_name` that is all dots or
ends in a dot is now a compile error.

Deferred, each cheap to add later: an `XDG_STATE_HOME` / `.state` kind, a
`permissions` knob (source-compatible as a defaulted field), handle-relative
no-follow creation, and `openDir`.
