# Review follow-ups — `zcli_secrets` plugin (PR #39)

- **Reviewer:** Fable (independent code review), 2026-07-02
- **PR:** #39 — `zcli_secrets` opt-in credential plugin (macOS Keychain / Linux Secret Service / Windows Credential Manager)
- **Status of this file:** a backlog of *deferred* items. Everything Fable rated
  blocking or cheap-and-clear was already addressed in the PR (commit `af398fc`);
  the items below were consciously left for later, with Fable's agreement that
  none block merge. Recorded here so they are not lost.

## Open items (not yet addressed)

### 1. Double-context API wart — needs a framework-level `initContextData` hook
- **Severity:** design / medium. **Where:** `plugins/zcli_secrets/plugin.zig` `ContextData`, and the plugin/registry framework (`packages/core/src/registry.zig`).
- **Problem:** the public API is `context.plugins.zcli_secrets.get(context, name)` — the context is passed twice. `ContextData` is default-initialized (`.{}`) with no init hook, so it can't capture `allocator`/`app_name` at construction; hence every call re-threads `context`. The `context: anytype` signature also erases the contract, so misuse surfaces as an instantiation error deep in the plugin.
- **Direction:** add an `initContextData(context)` hook to the plugin framework so a plugin's `ContextData` can capture what it needs once; then the API becomes `context.plugins.zcli_secrets.get(name)`. This is a framework change touching all plugins, not secrets-only — hence deferred.

### 2. Linux libsecret: base64 wrapper vs. raw `SecretValue`
- **Severity:** minor / polish. **Where:** `plugins/zcli_secrets/secret_service_linux.zig`.
- **Problem:** the variadic `secret_password_*_sync` helpers are NUL-terminated, so values are base64-encoded to stay binary-safe. Side effect: a value inspected via `secret-tool` shows base64, not the raw token.
- **Direction:** switch to `secret_service_store_sync` / `SecretValue` (length-based) to store raw bytes and preserve `secret-tool` interop. Cost is a `GHashTable`/`SecretValue` FFI surface (more glib marshalling) — a fair trade to defer while the base64 limitation is documented in the module and ADR.

### 3. No secure zeroing of transient secret buffers
- **Severity:** minor. **Where:** all backends — e.g. the base64 staging buffer in `secret_service_linux.zig` `set`, and the caller-owned copies returned by every `get`.
- **Problem:** plaintext secret material lingers in freed heap pages until reused; a core dump / memory scrape could recover it. Low severity for short-lived CLI processes, but cheap credibility for a "credentials done right" module.
- **Direction:** `std.crypto.secureZero(u8, buf)` on transient buffers before free. Returned buffers are caller-owned (arena), so scope carefully — likely only the internal staging buffers, plus a documented note that callers should zero what they free.

### 4. Windows key flattening can collide across apps
- **Severity:** minor / correctness edge. **Where:** `credential_manager_windows.zig` `makeTarget`.
- **Problem:** the credential target is the flattened string `"{app_name}:{name}"`, so two *different* apps whose `app_name`/`name` concatenate identically would share an entry (e.g. `("a:b","c")` vs `("a","b:c")`). A non-issue within one app (fixed `app_name`), and both must be same-user zcli apps, so very low real-world risk — currently documented rather than fixed.
- **Direction:** if ever needed, length-prefix or otherwise unambiguously encode the two components into the target name.

### 5. Windows value size cap (2560 bytes) is platform-asymmetric
- **Severity:** minor / portability. **Where:** `credential_manager_windows.zig` (`CRED_MAX_CREDENTIAL_BLOB_SIZE`), documented in `plugin.zig`.
- **Problem:** values over `CRED_MAX_CREDENTIAL_BLOB_SIZE` fail with `SecretTooLarge` only on Windows; some real tokens (large JWTs, certain PATs) exceed 2.5 KB. A CLI that works on macOS/Linux can fail only on Windows.
- **Direction:** documented for now. If it bites, chunk a large value across multiple credentials (`name`, `name#1`, …) transparently in the Windows backend.

### 6. Non-UTF-8 secret names behave differently per OS
- **Severity:** minor / contract. **Where:** `plugin.zig` `validateName`, `credential_manager_windows.zig`.
- **Problem:** Windows requires a valid-UTF-8 name (it becomes a UTF-16 target); macOS/Linux accept arbitrary bytes. Names are already validated to reject NUL, but not to require UTF-8, so a non-UTF-8 name "works" on two platforms and fails on the third.
- **Direction:** consider requiring valid, printable UTF-8 names centrally in `validateName` for a uniform cross-platform key contract. Slight tightening (names are identifiers in practice), so deferred as a deliberate contract decision.

## Already addressed in the PR (for reference)

- Public-API compile + round-trip coverage (live test now drives `ContextData` via a mock context, incl. a binary/NUL value) — Fable Important #1.
- Legible build error when the Linux backend is requested for a musl target — Fable Important #2.
- `InvalidSecretName` validation (reject embedded NUL) + documented Windows size/key constraints — Fable Important #3.
- Debug-level diagnostics on backend failure paths (OSStatus / GError / Win32 error; never a secret value) — Fable Important #4.
- Stale "file fallback" doc/step-description cleanup, CI keyring-wait fails loudly on timeout, PR title corrected — minors.
