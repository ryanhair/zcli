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

## Branch protection policy

The `main` branch ruleset (`Main Protection`, id `18284157`) enforces
deletion protection, non-fast-forward pushes, and all 15 CI status checks.
It does **not** include a `pull_request` rule — there is no required review
and no requirement to merge via PR — and it has one bypass actor (the
repository-admin role) with `bypass_mode: always`.

This is intentional, not an oversight:

- zcli is a solo-maintainer project. Direct pushes to `main` by the
  maintainer are accepted; requiring self-approved PRs for every change
  would add process without adding safety.
- The bypass actor exists because the release workflow's `finalize` job
  (`.github/workflows/release.yml`, the "Push to main and cut tags" step)
  pushes the staged release commit directly to `main` and cuts the release
  tags, using `GITHUB_TOKEN`. That push must clear the ruleset's
  non-fast-forward check, so *something* has to be able to bypass it — same
  actor covers both the maintainer's direct pushes and CI's release push
  today.
- All CI status checks still apply to the release commit before `finalize`
  runs (see the `setup`/`build` staging-branch dance in release.yml — the
  commit is fully tested on a scratch branch before promotion), so the
  absence of a `pull_request` rule does not mean untested code can land.

**Future hardening path** (not implemented, tracked as a follow-up): add a
`pull_request` rule requiring review, and scope the bypass actor to just the
release workflow (GitHub supports app/workflow-scoped bypass actors) instead
of an always-on repository role. That would close the gap where any
direct-push-capable actor — not just the release automation — can skip
review.

**Optional idea, not implemented**: a scheduled workflow step that asserts
the ruleset shape via `gh api repos/<owner>/<repo>/rulesets/18284157` and
fails loudly on drift, mirroring the release environment's runtime
self-check (see "Push to main and cut tags" above, and the `#397` lesson
that an unenforced protection rule fails silently rather than loudly). No
such check exists yet for the ruleset itself.
