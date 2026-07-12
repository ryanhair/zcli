# Release integrity anchored on a pinned minisign key

Status: accepted

ADR-0009 documented that zcli's release integrity was trust-on-first-use anchored
on GitHub: `checksums.txt` ships in the *same* release as the binaries, so anyone
who can publish a release can publish matching checksums. It recorded a detached
signature under a client-pinned key as "the right eventual answer," deferred until
the key could live somewhere the release credentials do not. This ADR is that
answer, now that the deferral triggers are met (1.0 hardening; third-party
distribution imminent).

The release now signs `checksums.txt` with **minisign** (Ed25519). The detached
signature `checksums.txt.minisig` ships as a release asset; the **public** key is
pinned in every client. Integrity stops depending solely on GitHub account
security: a compromised publisher can swap the binaries and rewrite the checksums,
but cannot forge a signature under a key that never enters the release pipeline.

## What is signed, and where the key lives

- **Sign `checksums.txt`, not each binary.** One signature covers all six
  artifacts, and both clients already fetch `checksums.txt` and match a binary's
  SHA-256 against it. Authenticating `checksums.txt` transitively authenticates
  every binary it names.
- **Offline custody (the load-bearing decision).** The signing secret key never
  touches CI. It is generated on the maintainer's machine, password-encrypted, and
  stored in a password manager (independent of any single machine; see
  `docs/RELEASE-SIGNING.md`). This is what makes the signature meaningful — a key
  sitting next to the release token would, as ADR-0009 warned, add ceremony
  without adding security. CI publishes the CLI release as a **draft**; the
  maintainer signs locally with `scripts/sign-release.sh` and flips it to
  published. Drafting until signed means fail-closed clients never observe an
  unsigned release, closing the verification-window race.

## Verification, per client

- **`zcli upgrade` (in-binary) — fail closed.** minisign signatures are Ed25519,
  so verification is a small pure-Zig parser over two base64 blobs plus one
  `std.crypto.sign.Ed25519` call (`packages/core/src/plugins/zcli_github_upgrade/minisign.zig`),
  with `std.crypto.blake2.Blake2b512` for minisign's prehashed mode. **No external
  tool, no C library** — the libc-free static release build is untouched. When a
  consuming app pins `github_upgrade`'s `public_key`, the upgrade fetches
  `checksums.txt.minisig`, verifies it *before* trusting any checksum, and aborts
  on a missing, malformed, or invalid signature. Both minisign algorithms (`ED`
  prehashed, `Ed` legacy) are accepted so verification never depends on the
  signer's minisign version.
- **`install.sh` (POSIX sh) — signature required, fail closed.** Pure-sh Ed25519 is
  not feasible, so the installer shells out to `minisign -V`. When a key is pinned,
  `minisign` is **required**: if it is absent the install aborts with per-platform
  install instructions rather than degrading to checksum-only. The alternative
  (verify-if-present, else checksum-only) was considered and rejected — it would
  leave the compromised-publisher threat unmitigated on the majority of `curl | sh`
  runs, where `minisign` is not installed. Requiring the tool keeps every install
  path as strong as the `upgrade` path, at the cost of one prerequisite.

The signing public key is **per-app config**, not hardcoded: `github_upgrade`'s
`public_key` defaults to null (checksum-only, for apps that do not sign) and zcli's
own build pins zcli's key.

## Considered options

- **Detached minisign signature, pinned public key (chosen)** — one Ed25519 check;
  verifiable in the static binary with zero new dependencies; the secret key lives
  off CI. Directly realizes ADR-0009's recommended-but-deferred option.
- **Key in a GitHub Actions secret, CI signs** — keeps a fully one-button release,
  but the key sits next to the release credentials. Defends a leaked *narrow*
  release token and transit/storage tampering, but not account takeover or a
  malicious workflow edit — the very threats the signature exists to address.
  Rejected: it is the "ceremony without security" case ADR-0009 named. A GitHub
  *environment* with a required-reviewer gate on a CI signing job was considered as
  a mitigation and left as a documented fallback only.
- **Sigstore/cosign keyless signing** — avoids long-lived keys but pulls a
  substantial verification dependency into the static binary and ties verification
  to an external transparency-log ecosystem. Disproportionate for zcli's audience
  (unchanged from ADR-0009).

## Key rotation and compromise

The ceremony — not the mechanics — is the real work; it lives in
`docs/RELEASE-SIGNING.md`: keygen, password-manager custody with an offline
backup, per-release signing, scheduled/void rotation, and the compromise
procedure. Rotation is a client-pinned-key change, so it propagates the way any
release does: a new pinned key ships in the next signed binary, and `zcli upgrade`
carries it forward. Already-shipped releases remain verifiable against the key
pinned in the binary that installed them.
