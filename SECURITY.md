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

Verified with authenticated administrative access on **2026-09-09**.

The active `main` ruleset is `Main Protection` (id `18284157`). Its public
rules are deletion protection, non-fast-forward protection, and the required
`CI OK` status check. The
strict-required-status-check policy remains disabled, and there is no
`pull_request` rule requiring PR-only merging or a second reviewer.

There is no `RepositoryRole` administrator bypass. Ordinary maintainer pushes
must satisfy the ruleset, including `CI OK`. Administrative permission to edit
repository settings is separate from permission to bypass branch rules.

The sole bypass actor is `DeployKey` with `actor_id: null` and
`bypass_mode: always`. This actor covers **all repository deploy keys**, not
just a named release key. A read-only key still lacks permission to push;
any write-capable deploy key can bypass the branch rules. The
[`finalize` job](.github/workflows/release.yml) uses it to fast-forward the
validated, staged release commit to `main`, after the `release` environment's
required-reviewer gate. Release tags use `GITHUB_TOKEN` over HTTPS instead.
The workflow also checks that the environment still has a required-reviewers
rule before using the key.

This exception still grants a direct-write capability: GitHub's ruleset does
not limit the deploy-key bypass to that job or require `CI OK` from it. Protect
all deploy keys and the release environment accordingly. Adding a new
write-capable deploy key expands this exception. Replacing it requires a
release flow that promotes the staged commit through required checks without
a direct branch push; simply removing the key bypass would break releases.

CI checks the publicly observable rule shape on every PR and `main` push:
the ruleset name/id, its default-branch target, its three rule types, `CI OK`,
and the non-strict policy. It fails if GitHub's public API cannot be read or
the shape drifts. The anonymous endpoint does not expose bypass actors, so
this check cannot verify the absence of administrator bypasses. Audit them
with authenticated administrative access:

```sh
gh api repos/ryanhair/zcli/rulesets/18284157 \
  --jq '{enforcement, conditions, rules, bypass_actors}'
gh api repos/ryanhair/zcli/keys --jq '.[] | {id, title, read_only}'
```

Expect one bypass actor: `DeployKey`, `bypass_mode: always`; no
`RepositoryRole` actor. Audit the key inventory as well: the expected sole key
is `zcli-release-key` (id `157632853`, write-capable). Also verify that
`repos/ryanhair/zcli/environments/release` still has a `required_reviewers`
protection rule whenever changing release permissions.
