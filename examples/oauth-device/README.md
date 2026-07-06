# oauth-device — a `zcli.http` + `zcli_secrets` device-flow example

The companion to [`ghauth`](../ghauth). Where `ghauth` pastes a token you already
have, `oauth-device` *mints* one: `login` runs GitHub's OAuth **device flow**
(RFC 8628), stashes the resulting token in your OS keychain, and then `whoami`
and `logout` behave exactly like `ghauth` — because once the flow is done, it's
the same opaque credential.

```
$ export GITHUB_CLIENT_ID=Iv1_xxxxxxxx      # your OAuth app's client ID
$ oauth-device login
To authorize, open:

    https://github.com/login/device

and enter the code:  WXYZ-1234

Waiting for you to authorize…

Authorized. Try `oauth-device whoami`.
$ oauth-device whoami
Ada Lovelace (@ada)
$ oauth-device logout
Removed your stored GitHub token.
```

A **canonical example** (ADR-0004): a compiled, CI-checked teaching artifact —
here, for the "how do I actually implement OAuth in a CLI?" question.

## Why this is an example, not a framework feature

zcli deliberately does **not** ship an OAuth library. The two *hard* parts of CLI
auth are already framework features you get for free:

- **`zcli.http`** — a TLS-verified client that strips `Authorization` if a
  redirect ever leaves the origin, so a bearer token can't leak to another host.
- **`zcli_secrets`** — native keychain storage (macOS Keychain / Linux Secret
  Service / Windows Credential Manager), never a plaintext file.

What's left — the device flow itself — is ~150 lines of freeform command code
(ADR-0003), and the part that varies (endpoints, `client_id`, scopes) is
provider-specific. So it lives here as a pattern to copy, not as an abstraction
to configure. Point it at another provider by swapping the three URLs and the
client_id in [`src/commands/login.zig`](src/commands/login.zig); the flow is
unchanged.

## What it demonstrates

- **The RFC 8628 device flow, end to end** — request a device + user code, show
  the user where to enter it, then poll the token endpoint on the server's
  interval. The easy-to-botch bit — deciding `authorization_pending` vs
  `slow_down` vs a terminal error — is a pure `classifyError` function with a
  unit test (`zig build test`).
- **Flushing buffered stdout** — the user code is printed and `stdout.flush()`ed
  *before* the polling loop blocks, so they can actually read it.
- **`zcli.http` for form POSTs** — `application/x-www-form-urlencoded` bodies with
  an `Accept: application/json` header so `Response.json` can parse the reply.
- **`zcli_secrets` as the handoff** — `login` calls `set`, `whoami` calls `get`,
  `logout` calls `delete`. The plugin only ever stores/reads the opaque token; it
  neither knows nor cares that this one came from a device flow.
- **`context.fail`** — every expected failure (denied, expired, timed out, no
  `GITHUB_CLIENT_ID`, rejected token) is a clean one-line message and a non-zero
  exit, no stack trace.

> Enabling `zcli_secrets` links a native keychain library on macOS/Windows and,
> on Linux, shells out to `secret-tool` or `pass` at runtime (ADR-0010) — the
> binary stays static. That's the opt-in cost ADR-0003 keeps off projects that
> don't store secrets.

## Run it

Register an OAuth app with **device flow enabled** at
<https://github.com/settings/developers>, then:

```
GITHUB_CLIENT_ID=Iv1_xxxxxxxx zig build run -- login
```
