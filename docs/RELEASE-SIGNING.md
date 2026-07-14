# Release signing

zcli releases are signed so that anyone installing or upgrading can verify the
binaries came from the zcli maintainer — not merely from whoever could publish a
GitHub release. The mechanism is a [minisign](https://jedisct1.github.io/minisign/)
(Ed25519) detached signature over `checksums.txt`; the public key is pinned in the
clients. See [ADR-0023](adr/0023-release-signing-minisign.md) for the rationale and
[ADR-0009](adr/0009-release-integrity-trust-model.md) for the threat model it closes.

**The security of this rests entirely on the custody of the secret key.** The
mechanics below take an afternoon; the custody discipline is the actual work.

---

## Trust model in one paragraph

`checksums.txt` ships in the same release as the binaries, so a compromised
publisher can swap a binary and rewrite its checksum. A signature under a key that
**never enters the release pipeline** breaks that: the attacker cannot forge it.
The value is real only while the secret key lives somewhere the GitHub release
credentials do not — so the key is generated offline, stored in a password
manager, and used to sign releases locally. It is never a GitHub Actions secret.

---

## One-time setup (the keygen ceremony)

Do this once, on a trusted machine, in a private location.

### 1. Generate the keypair

```sh
# minisign 0.12+  (brew install minisign)
mkdir -p ~/.minisign
minisign -G -s ~/.minisign/minisign.key -p ~/.minisign/zcli.pub
```

You will be prompted for a **passphrase**. Choose a strong, unique one — it
encrypts the secret key at rest. Without the passphrase the key file is useless to
a thief; with a weak passphrase it is not, so treat it like a root password.

This writes:
- `~/.minisign/minisign.key` — the **secret** key (passphrase-encrypted, ~200 bytes).
- `~/.minisign/zcli.pub` — the **public** key. Its second line is the base64 blob
  clients pin.

### 2. Store custody (password manager as source of truth)

The single-machine copy is not the custody plan — it is a working copy. Put the
real custody in a password manager:

1. Store `minisign.key` (the file, or its contents) as a **secure document / note**
   in your password manager (1Password, Bitwarden, …). It syncs and is backed up
   independently of any one machine — so a dead or stolen laptop is not a lost key.
2. Store the **passphrase** as a *separate* entry (not next to the key). The two
   must be compromised together to matter; keeping them apart means a leak of one
   is not a compromise.
3. **Offline backup (belt and suspenders):** also copy the encrypted `minisign.key`
   to an encrypted USB drive or print it, kept physically separate. This is your
   recovery path if the password manager itself is ever lost.

> Why this and not a GitHub Actions secret: a key in CI can sign, but it also sits
> next to the release token — an account takeover or a malicious workflow edit
> could use it, which is exactly the threat signing exists to stop. Off-CI custody
> is the whole point (ADR-0023).

### 3. Pin the public key in the repo and clients

Print the public key and wire it into three places:

```sh
cat ~/.minisign/zcli.pub
# untrusted comment: minisign public key XXXXXXXXXXXXXXXX
# RWR....................................................   <- the base64 blob
```

1. **Committed public key file** — save the whole `.pub` to `docs/zcli-minisign.pub`
   (the signing script self-verifies against it, and it is the file users verify
   with).
2. **`install.sh`** — set `MINISIGN_PUBKEY="RWR..."` (the base64 blob) near the top.
3. **`projects/zcli/build.zig`** — set
   `.verification = .{ .minisign = "RWR..." }` in the `github_upgrade` builtin,
   so `zcli upgrade` enforces the signature natively. (`verification` has no
   default — every consuming app must pick `.minisign` or the explicit
   `.checksum_only` opt-out.)

Commit these together. Signature enforcement is now live for the **next** release.

---

## Signing a release (every release)

The release workflow publishes the CLI release as a **draft** (binaries +
`checksums.txt`, unsigned). Turn it into a published, signed release from your
machine:

```sh
# Make the secret key available for the duration (from your password manager).
# Either point at your working copy…
scripts/sign-release.sh 0.20.0

# …or export the key from your password manager to a temp file and pass it:
#   op document get "zcli minisign key" --out ./key.sec   # example
#   scripts/sign-release.sh -s ./key.sec 0.20.0
#   rm -f ./key.sec
```

The script downloads `checksums.txt` from the draft, signs it (prompting for your
passphrase), self-verifies against `docs/zcli-minisign.pub`, uploads
`checksums.txt.minisig`, and flips the release to published. Never publish a CLI
release draft by hand — that would ship it unsigned.

### How a user verifies (for the docs / the paranoid)

```sh
gh release download zcli-v0.20.0 -p 'checksums.txt*'
minisign -Vm checksums.txt -p docs/zcli-minisign.pub
# then check a binary's line in the (now-trusted) checksums.txt
```

---

## Key rotation

Rotate on a schedule (e.g. yearly) or immediately on suspected compromise. Because
the public key is pinned in each client, rotation propagates like any release: the
new key ships in the next signed binary, and `zcli upgrade` carries it forward.
Releases already installed remain verifiable against the key pinned in the binary
that installed them.

**Planned rotation:**

1. Generate a new keypair (setup step 1) into a new file; store custody (step 2).
2. Pin the **new** public key everywhere (step 3) and cut a release signed with the
   **new** key. Users on the current version upgrade to it, pinning the new key
   going forward.
3. Keep the old secret key in cold storage for one release cycle (in case a
   re-sign of the transition release is needed), then destroy it.

---

## Compromise procedure

If the secret key may be exposed (lost passphrase discipline, leaked backup,
compromised machine), assume it is compromised and act fast:

1. **Announce.** Post a security notice (README banner, GitHub release notes,
   `zcli.sh`) stating the key is revoked and which releases predate the revocation.
   An attacker with the key can forge signatures, so the out-of-band announcement
   is the real defense — pinned keys cannot self-revoke.
2. **Rotate immediately** (rotation steps above) with a fresh key whose custody is
   clean. Do **not** reuse any backup that might share the exposure.
3. **Re-sign or re-cut** the latest good release under the new key so users have a
   verifiable artifact to move to.
4. **Verify downstream.** If a Homebrew tap or distro packaging pins the old key,
   push the new key to them.
5. **Post-mortem.** Record how the key was exposed and tighten custody (offline
   backup handling, passphrase strength, machine hygiene).

Note the asymmetry: a *lost* key (gone, but not in an attacker's hands) is a mild
event — no one can forge with it, so just rotate at leisure. A *compromised* key
(in someone else's hands) is the urgent case above. Custody discipline is what
keeps you in the first category.
