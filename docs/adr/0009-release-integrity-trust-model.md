# Release integrity anchors on the GitHub release, unsigned (for now)

Status: accepted — signing deferral resolved by [ADR-0023](0023-release-signing-minisign.md)

> **Update:** the "Trigger to revisit" below is now met. Release signing landed as
> [ADR-0023](0023-release-signing-minisign.md): `checksums.txt` is signed with a
> minisign key held offline (never in CI) and verified against a client-pinned
> public key. The trust model this ADR documents is the pre-signing baseline; the
> checksum enforcement it describes still runs, now underneath the signature.

zcli has two trust-establishing distribution paths: the `curl | sh` installer
(`install.sh`) and the self-upgrade plugin (`zcli_github_upgrade`). Both fetch
a binary **and** a `checksums.txt` from the same GitHub release over HTTPS,
verify the binary's SHA-256 against the checksum file, and fail **closed**:
the installer aborts if checksum tooling is unavailable or the checksum file
cannot be fetched; the plugin errors on a missing or mismatched digest, with
the checksum line matched by exact filename. The upgrade additionally
downloads into a private randomly-named scratch directory, smoke-tests that
the staged binary actually execs, and swaps it in atomically with a backup.

This ADR records what that design does and does not defend against, because
the security audit found the trust model implemented but nowhere written down
— and an unlegible trust model invites both false confidence and false alarms.

## What the checksum defends against

- Corruption or truncation in transit (including through proxies and mirrors).
- Asset mix-ups: downloading the wrong platform's binary, or a stale/partial
  asset, fails verification instead of getting installed. The exec smoke test
  then catches the residual case a digest cannot (a correctly-published asset
  that is simply the wrong architecture under this platform's name).

## What it does not defend against

`checksums.txt` ships in the **same release** as the binaries, so anyone who
can publish a release can publish matching checksums. Integrity therefore
reduces to the security of:

1. the maintainer's GitHub account and any tokens with release permission, and
2. GitHub itself (release storage and the HTTPS endpoints).

This is trust-on-first-use anchored on GitHub. A compromised maintainer token
or a malicious release pipeline defeats checksum verification by construction
— only a signature under a key the *client already holds* would catch it.

## Considered Options

- **Detached signature over `checksums.txt` (minisign/OpenBSD signify style),
  public key pinned in the client** — the right eventual answer: one small
  signature check in the installer and upgrade plugin, and release integrity
  stops depending solely on GitHub account security. Deferred, not rejected:
  it introduces a real signing key to generate, protect, back up, and rotate,
  and a compromised signing key stored *next to* the release credentials adds
  ceremony without adding security. The value arrives when the key lives
  somewhere the release token does not.
- **Sigstore/cosign keyless signing** — avoids long-lived keys, but pulls a
  substantial verification dependency into a libc-free static binary and ties
  verification to an external transparency-log ecosystem. Disproportionate
  for zcli's current audience.
- **Document the model, defer signing (chosen)** — the enforcement that
  exists (fail-closed checksums, exact matching, scratch-dir download, atomic
  swap, exec smoke test) is real and tested; what was missing was a written
  statement of where its guarantees end. This ADR is that statement.

## Trigger to revisit

Add release signing when any of these becomes true: zcli binaries are
distributed beyond the maintainer's own projects (meaningful third-party
install base); releases start being published by CI with long-lived
credentials rather than an interactive maintainer session; or a package
ecosystem (Homebrew tap, distro packaging) wants a verifiable upstream
artifact. The deferred-work entry in `TODOS.md` carries the effort estimate.
