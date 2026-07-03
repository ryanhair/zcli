# ghauth — a `zcli_secrets` + `zcli.http` example

An authenticated GitHub client. `login` stashes a token in your OS keychain,
`whoami` uses it to call the API, `logout` forgets it.

```
$ export GITHUB_TOKEN=ghp_xxx
$ ghauth login
Saved your GitHub token to the OS keychain. Try `ghauth whoami`.
$ ghauth whoami
Ada Lovelace (@ada)
$ ghauth logout
Removed your stored GitHub token.
```

A **canonical example** (ADR-0004): a compiled, CI-checked teaching artifact for
the credential-storage idiom. See
[`src/commands/`](src/commands).

What it demonstrates:

- **`zcli_secrets`** — enabled with `zcli.builtin(.secrets, .{})` in `build.zig`,
  then reached as `context.plugins.zcli_secrets.{set,get,delete}` with no import.
  The token lives in the OS keychain (macOS Keychain, Linux Secret Service,
  Windows Credential Manager) — never a plaintext file.
- **The auth flow is freeform command code, not a framework feature** (ADR-0003):
  `login` just reads `$GITHUB_TOKEN` (kept out of argv so it never lands in shell
  history). A real CLI might swap that for an OAuth device-code flow — the plugin
  only ever stores/reads the resulting opaque credential.
- **`zcli.http` with auth** — `whoami` sends `Authorization: Bearer …`; the client
  strips that header if a redirect ever leaves GitHub's origin, so a token can't
  leak to another host.
- **Graceful states** — clear errors for "no `$GITHUB_TOKEN`", "not logged in",
  and a rejected (401) token.

> Enabling `zcli_secrets` links a native keychain library (libsecret on Linux;
> nothing extra on macOS/Windows). That's the opt-in cost ADR-0003 keeps off
> projects that don't store secrets.

Run it:

```
GITHUB_TOKEN=ghp_xxx zig build run -- whoami
```
