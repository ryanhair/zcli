# Secrets storage is an opt-in plugin, not core

Status: accepted

An HTTP client with safe defaults (TLS verification on by default, a bounded response body, and an overall request timeout) belongs in core — nearly all CLIs make HTTP calls, so it passes the "genuine use-case in a large portion of CLIs" test universally (ADR-0002). Secrets storage passes that test too, but only for the *service-client* category of CLI (those with a `login`/`auth` step that persists a token), not utility CLIs. More importantly, real OS keychain backends (Linux Secret Service via D-Bus/libsecret, Windows Credential Manager) require dynamic linking and would compromise zcli's static-single-binary (libc-free musl) property for *everyone*, including authors who never store a secret. Therefore secrets ship as an **opt-in `zcli_secrets` plugin** — keychain-backed where available with a documented fallback — so the portability cost is paid only by those who opt in.

## Considered Options

- **Secrets in core** — rejected: forces the keychain/dynamic-linking portability cost on all CLIs.
- **No secrets support** — rejected: leaves a dominant CLI category to hand-roll credential storage.
- **Opt-in plugin (chosen)** — pays the cost only on opt-in, matches the existing plugin pattern (config, output, completions, upgrade).

## Scope boundary

The plugin covers *storage/retrieval of an opaque credential* (`get`/`set`/`delete` a named secret). It does **not** cover the auth flow that produces the credential (OAuth, device-code, etc.) — that is service-specific domain logic, left to freeform command code plus shipped patterns.

## Implementation outcome

Implemented as `packages/core/src/plugins/zcli_secrets/`. The plugin holds no state; its API is reachable from command code as `context.plugins.zcli_secrets.{get,set,delete}(context, name, ...)` — no import needed, and the field only exists (so the calls only compile) when the app registers the plugin via `zcli.builtin(.secrets, .{})`.

The backend is selected at **compile time** from the target OS:

- **macOS** → the OS Keychain (`keychain_macos.zig`), storing each secret as a generic-password item keyed by `(service = app_name, account = name)`. It uses the flat `SecKeychain*GenericPassword` C API deliberately: it needs no CoreFoundation dictionary marshalling, keeping the FFI small and auditable.
- **all other targets** → a pure-Zig, file-backed fallback (`file_store.zig`): a JSON map of name → base64(value) in `$XDG_DATA_HOME/{app}` (falling back to `$HOME/.local/share/{app}`), with the directory forced to `0700` and the file to `0600`. Values are plaintext at rest — filesystem permissions are the only protection, which the module documents. Linux Secret Service and Windows Credential Manager backends can slot in later behind the same wiring.

The opt-in portability guarantee is enforced in **two halves**: the source half is the compile-time backend selection above (a non-macOS or non-registered build never references the keychain symbols); the build half is in `generate()`, which links `Security` + `CoreFoundation` into the executable **only** when `zcli_secrets` is registered on a macOS target. Verified with `otool -L` on the `showcase` example: without the plugin the binary links only `libSystem`; adding `zcli.builtin(.secrets, .{})` is what makes the two frameworks appear. A CLI that does not opt in stays a static, libc-free single binary.

## Note: what "safe defaults" means for the HTTP client

The safe defaults the core HTTP client (`zcli.http`) enforces are:

- **TLS verification on** — no knob to disable it.
- **A bounded response body** — a hostile or runaway server cannot exhaust memory; the read fails with `error.ResponseTooLarge`.
- **An overall request timeout** (default 30s, configurable per client and per request, disable-able) — a hung or dead server cannot make a command hang forever; the request fails with `error.Timeout`.
- **Bounded redirects**, not auto-followed for requests carrying a payload.

The timeout deserves a note because `std.http.Client` exposes no timeout of its own — in Zig 0.16 timeouts and cancellation live in the `std.Io` layer. So the client enforces the timeout there: it runs the request as a concurrent task raced against a timer (`std.Io.Select`) and cancels the loser. Cancellation is delivered at the request's next I/O cancellation point (connect / TLS handshake / read), which is exactly where a stuck request blocks. (An earlier draft of this decision claimed the client "cannot enforce a timeout"; that was wrong — it conflated "no timeout *parameter* on `std.http.Client`" with "no timeout possible," and was corrected once the `std.Io` `Select`/cancel surface was verified against the standard library.)
