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
  `scripts/release.sh` and then publishes it. This means a compromised
  GitHub account or CI workflow can swap binaries and rewrite checksums, but
  cannot forge a valid signature.
- The **public** key is pinned in the clients: `install.sh` and `install.ps1`
  require `minisign` and verify the signature before installing anything (fail
  closed — neither falls back to checksum-only verification if `minisign` is
  missing), and `zcli upgrade` verifies it natively in pure Zig (no external
  tool, no libc dependency) before trusting any checksum.
- The signature is **bound to its release tag**. `checksums.txt` names artifacts
  but carries no version, so an authentic signature alone cannot distinguish a
  current release from an older one — an actor able to influence which release
  `releases/latest` resolves to could otherwise replay a genuinely-signed older,
  vulnerable build. The signing ceremony writes the tag into minisign's trusted
  comment (covered by minisign's second, "global" signature), and every client
  requires that comment to name the exact tag being installed as a whole token,
  refusing the install otherwise (CWE-294). `scripts/release.sh` checks the
  same binding before publishing, so a mistyped tag fails at signing time rather
  than for every user afterwards.
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

## Branch protection policy

As verified with authenticated GitHub access on 2026-07-29, the active `main`
ruleset is `Main Protection` (id `18284157`). It enforces exactly deletion
protection, non-fast-forward pushes, and one required status check: `CI OK`.
Its strict-required-status-check policy is disabled, so an up-to-date branch
is not required when that check has already passed. It has no `pull_request`
rule: review and PR-only merging are not required.

The authenticated ruleset response lists two `bypass_mode: always` actors:
the release `DeployKey` and `RepositoryRole` id `5`. The latter is an
always-on role bypass, not a release-only exception. Either actor can bypass
the ruleset, including its required check; possession or use of the release
deploy key is therefore a direct-write capability for `main`, not merely
checkout access.

The release exception and its remaining risk are:

- The release deploy key exists for one operation: the
  [`finalize` job](.github/workflows/release.yml)'s fast-forward promotion of
  the approved, staged release commit to protected `main`. The workflow uses
  that key only for the branch push; it pushes release tags through an HTTPS
  remote authenticated by `GITHUB_TOKEN`. The key is the deploy-key bypass
  actor that makes the protected-branch promotion possible.
- The release workflow validates the staged release commit before `finalize`
  promotes it (see the `setup`/`build` staging-branch sequence in
  `release.yml`). That workflow validation does not remove the risk of an
  always-bypass actor: the ruleset itself cannot require `CI OK` or review
  from either bypass actor.
- zcli is a solo-maintainer project, so direct pushes by the maintainer remain
  accepted. The repository-role bypass is broader than that workflow use and
  has no release-only scope.

**Future hardening path** (not implemented, tracked as a follow-up): add a
`pull_request` rule requiring review, and replace the always-on role bypass
with the narrowest release-only mechanism GitHub supports. That would reduce
the gap where a bypass-capable principal can land unreviewed or unchecked
code.

CI checks the publicly observable rule shape on every PR and `main` push:
the ruleset name/id, its default-branch target, its three rule types, `CI OK`,
and the non-strict policy. It fails if GitHub's public API cannot be read or
the shape drifts; it does not skip for an unavailable API. GitHub's anonymous
ruleset endpoint exposes the rules but returns `bypass_actors: null`, so that
check deliberately does **not** claim to validate bypass actors. Re-check
bypass actors with authenticated administrative access when auditing this
policy.
