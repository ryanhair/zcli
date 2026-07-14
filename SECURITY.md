# Security policy

## Reporting a vulnerability

Please **do not** open a public issue for security vulnerabilities. Instead, use
GitHub's private reporting flow:

1. Go to the [Security tab](https://github.com/ryanhair/zcli/security) of this repo.
2. Click **Report a vulnerability** to open a private security advisory.

This reaches the maintainer directly without disclosing details publicly while a
fix is worked out. If that's not available to you for some reason, you can
instead contact the maintainer ([@ryanhair](https://github.com/ryanhair)) through
their GitHub profile.

Please include:

- The version/tag (or commit) affected.
- A minimal reproduction if possible.
- The impact you believe it has (e.g. arbitrary code execution during upgrade,
  bypassed signature verification, path traversal in generated code, etc.).

There is no fixed SLA — this is a single-maintainer project — but reports will be
acknowledged and triaged as soon as possible, and a fix or mitigation will ship
before any public disclosure.

## Supported versions

zcli is pre-1.0 and ships from `main`. Security fixes land on the latest release
only; there is no long-term-support branch to backport to.

## Release signing and verification model

CLI releases (the `zcli-vX.Y.Z` tags, which carry the prebuilt meta-CLI binaries)
are signed with [minisign](https://jedisct1.github.io/minisign/) (Ed25519):

- `checksums.txt` lists a SHA-256 for every release binary, and `checksums.txt`
  itself is signed — `checksums.txt.minisig` ships as a release asset.
- The **secret** signing key is generated and kept offline (password-manager
  custody); it never touches CI. The release workflow only publishes a
  **draft** release; the maintainer signs `checksums.txt` locally with
  `scripts/sign-release.sh` and then publishes it. This means a compromised
  GitHub account or CI workflow can swap binaries and rewrite checksums, but
  cannot forge a valid signature.
- The **public** key is pinned in the clients: `install.sh` requires `minisign`
  and verifies the signature before installing anything (fail closed — it does
  not fall back to checksum-only verification if `minisign` is missing), and
  `zcli upgrade` verifies it natively in pure Zig (no external tool, no libc
  dependency) before trusting any checksum.
- Apps built with zcli's `zcli_github_upgrade` plugin must explicitly choose a
  verification mode — `.{ .minisign = "<public key>" }` or the explicit opt-out
  `.checksum_only` — there is no silent default that skips verification.

The full trust model, threat model, and the key rotation/compromise procedure
are documented in [docs/RELEASE-SIGNING.md](docs/RELEASE-SIGNING.md),
[ADR-0023](docs/adr/0023-release-signing-minisign.md), and
[ADR-0009](docs/adr/0009-release-integrity-trust-model.md).

**Scope note**: this signing scheme covers zcli's own `zcli-v*` CLI releases.
It does not automatically extend to apps built *with* zcli — those apps must
configure `zcli_github_upgrade`'s `verification` option (and run their own
signing ceremony) to get the same guarantee for their own releases.

The library releases (the `vX.Y.Z` tags consumed via `build.zig.zon`) are not
signed with minisign — `zig fetch`'s content-hash pinning is the integrity
mechanism there, verified against the hash recorded in your `build.zig.zon`.
