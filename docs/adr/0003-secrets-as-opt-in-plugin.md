# Secrets storage is an opt-in plugin, not core

Status: proposed

An HTTP client with safe defaults (TLS verification, timeouts) belongs in core — nearly all CLIs make HTTP calls, so it passes the "genuine use-case in a large portion of CLIs" test universally (ADR-0002). Secrets storage passes that test too, but only for the *service-client* category of CLI (those with a `login`/`auth` step that persists a token), not utility CLIs. More importantly, real OS keychain backends (Linux Secret Service via D-Bus/libsecret, Windows Credential Manager) require dynamic linking and would compromise zcli's static-single-binary (libc-free musl) property for *everyone*, including authors who never store a secret. Therefore secrets ship as an **opt-in `zcli_secrets` plugin** — keychain-backed where available with a documented fallback — so the portability cost is paid only by those who opt in.

## Considered Options

- **Secrets in core** — rejected: forces the keychain/dynamic-linking portability cost on all CLIs.
- **No secrets support** — rejected: leaves a dominant CLI category to hand-roll credential storage.
- **Opt-in plugin (chosen)** — pays the cost only on opt-in, matches the existing plugin pattern (config, output, completions, upgrade).

## Scope boundary

The plugin covers *storage/retrieval of an opaque credential* (`get`/`set`/`delete` a named secret). It does **not** cover the auth flow that produces the credential (OAuth, device-code, etc.) — that is service-specific domain logic, left to freeform command code plus shipped patterns.
