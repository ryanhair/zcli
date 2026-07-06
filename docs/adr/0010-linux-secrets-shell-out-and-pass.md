# Linux secrets: shell out instead of linking, and add `pass` as a runtime-detected backend

Status: accepted

ADR-0003 made secrets an opt-in `zcli_secrets` plugin backed by a real OS keychain, with the Linux backend talking to the freedesktop Secret Service via **libsecret** (`libsecret-1` + glib, linked at build time). That choice has two problems, and this ADR fixes both without weakening the security stance ADR-0003 set.

1. **libsecret/glib is glibc — it breaks musl.** A static, libc-free single binary *is* zcli's identity, yet a CLI that opts into `zcli_secrets` on Linux cannot build for musl at all. The codebase papers over this with a build-graph `std.debug.panic` for musl targets (`main.linkSecretsBackend`) and `null` backend carve-outs in `packages/core/build.zig` — a flagship property fighting a dependency, with the sharp edge pushed onto whoever opts in.
2. **Secret Service needs a desktop session.** It requires a running D-Bus session bus and an unlocked keyring daemon (gnome-keyring / KWallet). On a headless server, an SSH session, a container, or CI it is simply absent — and those are exactly the environments where a *service-client* CLI (the category the plugin exists for, per ADR-0003's scope boundary) authenticates and stores a token. Our own CI has to stand up `dbus-run-session` + `gnome-keyring-daemon --unlock` just to test the path.

The framing "Secret Service vs `pass`" hides that these are two independent axes: **linkage** (link a glibc library → breaks musl, vs. shell out to a binary → musl-clean) and **coverage** (works only in a desktop session, vs. also headless). `pass` wins on both, but not because it is `pass` — because it is a *shell-out* (no linkage) to a *file-based* store (no session daemon). Those two properties are what we actually want.

## Decision

**Two changes on Linux; macOS and Windows are untouched (still FFI to the OS Keychain / Credential Manager).**

1. **Stop linking libsecret/glib. Reach the Secret Service by shelling out to `secret-tool`** (from `libsecret-tools`). The stored item is identical — same daemon-encrypted Secret Service, same `(service = app_name, account = name)` attributes — but zcli no longer links glibc, so **Linux secrets stops breaking musl**. The build-graph musl `panic` and the `null`-backend carve-outs are deleted; `linkSecretsBackend` links nothing on Linux.

2. **Add `pass` (passwordstore.org) as a second Linux backend, selected at runtime.** Resolution order, resolved per operation (these ops are rare and user-triggered, and the plugin holds no state, so there is nothing to cache):
   1. **`ZCLI_SECRETS_BACKEND`** — an explicit override, `secret-service` or `pass`. An unknown value is a clear error, not a silent fallthrough. This is the escape hatch for a desktop user who prefers `pass`, or a headless setup where autodetection would guess wrong.
   2. **Secret Service** — chosen when `secret-tool` is present *and* a session bus is reachable (`DBUS_SESSION_BUS_ADDRESS`). The bus check is what makes a headless box fall through instead of hanging on a dead daemon.
   3. **`pass`** — chosen when the `pass` binary is present *and* the store is initialized (a `.gpg-id` exists under `PASSWORD_STORE_DIR` / `~/.password-store`, i.e. `pass init` has been run).
   4. **Neither** — an actionable error naming both options and how to set up either, plus the override.

## Considered Options

- **Keep libsecret, keep guarding musl (status quo)** — rejected: leaves the flagship static-binary property broken on Linux for every opt-in CLI, and offers no headless support at all.
- **Talk the D-Bus wire protocol directly from Zig** — rejected: musl-clean, but a large protocol implementation to maintain and audit for zero user-visible benefit over invoking `secret-tool`.
- **Replace Secret Service entirely with `pass`** — rejected: `pass` requires `gpg` + a configured GPG key (`pass init`), a deliberate power-user setup. Dropping Secret Service would strip the zero-config desktop keyring out from under GUI-desktop users who have a keyring but have never touched GPG.
- **Shell out to `secret-tool`, and add `pass` as a runtime-detected second backend (chosen)** — covers the desktop-keyring user and the headless/`pass` user with a single static binary, and lets either be forced explicitly.

## Consequences

- **Build-time library dependency → runtime binary dependency.** Instead of needing `libsecret` dev headers to *build*, an opt-in CLI needs `secret-tool` *or* `pass` present at *run* time — but only the one actually used, and the zcli binary stays static and libc-free. This is the trade that buys back musl.
- **Opaque-bytes contract is preserved with base64, now uniformly.** `secret-tool` takes the secret as a line on stdin, and `pass` is line-oriented over stdin/stdout, so neither round-trips arbitrary bytes (embedded NUL / newlines) unchanged. Both backends base64-encode on write and decode on read — same approach ADR-0003 already used for libsecret, now shared. (A value inspected via `secret-tool` or `pass show` therefore reads as base64.)
- **Namespacing.** Secret Service keeps the `(service = app_name, account = name)` attributes. `pass` is path-based, so entries live at **`zcli/<app_name>/<name>`** — the `zcli/` prefix keeps the plugin from clobbering a user's unrelated `pass` entries and makes ownership legible in `pass ls`.
- **Security posture is unchanged and still consistent with ADR-0003.** The Secret Service path stores in the same daemon-encrypted keyring. `pass` stores GPG-encrypted files — that is *not* the plaintext-file fallback ADR-0003 rejected; it sits between an OS keychain and plaintext, encrypted at rest under the user's GPG key. The "no silent, weaker-than-expected store" rule holds: if no real backend is available the plugin errors, it does not write plaintext. `pass` decryption may prompt for a GPG passphrase via the user's `gpg-agent`/pinentry — inherent to `pass`, and a failure there surfaces as an error rather than a downgrade.
- **The backend interface gains `io` and `environ`.** Shelling out needs to spawn a child process (Zig 0.16 `std.process` requires `io`) and to pass the ambient environment through to `secret-tool`/`pass`/`gpg` (`HOME`, `DBUS_SESSION_BUS_ADDRESS`, `GNUPGHOME`, `PASSWORD_STORE_DIR`, `GPG_TTY`, …). Both are threaded from the context — never read via C `getenv` — per project convention. The macOS and Windows FFI backends accept and ignore them.
- **CI.** The Linux `secrets` job drops the `libsecret` dev packages. The live round-trip now exercises **both** Linux paths: the Secret Service path under `dbus-run-session` + `gnome-keyring` with `secret-tool` installed, and the `pass` path with `gpg` + a throwaway key + `pass init`.

## Relationship to ADR-0003

ADR-0003 stands: secrets remain an opt-in plugin, backed by a real encrypted store, with no plaintext fallback and a compile-time error on unsupported targets. This ADR only changes *how the Linux backend reaches its store* (shell out, not link) and *how many Linux stores it supports* (Secret Service and `pass`, chosen at runtime). The "Linux → libsecret" and "musl → panic" specifics in ADR-0003's implementation-outcome section are superseded by this document.
