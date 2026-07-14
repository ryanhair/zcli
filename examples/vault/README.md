# vault

A secrets-backed CLI that stitches together the four features a realistic
"secrets + prompts" app needs, which previously only existed split across
separate examples:

- **`zcli_secrets`** — `set`/`get`/`remove` store and retrieve values in the OS
  keychain / Credential Manager / Secret Service (never a plaintext file).
- **`zcli_config`** — `list --verbose` defaults from `.vault.config.json`.
- **`zcli_completions`** — static shell completion, plus a dynamic `.complete`
  hook on `get`/`remove`'s `<name>` argument that offers the names actually
  stored.
- **prompts** — `set` reads the secret value from a hidden `password` prompt
  and confirms before overwriting/deleting.

Secret *values* never touch disk — only a small JSON index of *names*
(`.vault-index.json`) is kept alongside, so `list` and the dynamic completion
have something to enumerate.

```
vault set github-token   # prompts for the value (hidden input)
vault get github-token
vault list
vault remove github-token
```

## Build

```
zig build
./zig-out/bin/vault --help
```
