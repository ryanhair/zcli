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

## Cross-target smoke test coverage (accepted gap)

`release.yml`'s `build` job runs `--version`/`--help` against the binary it just
produced before it's ever published — but only where the runner can actually
execute the artifact:

- `x86_64-linux-musl` and `aarch64-macos` run natively.
- `x86_64-macos` runs under Rosetta 2 (installed as a build step on the
  `macos-latest` arm64 runner).
- `aarch64-linux` and both Windows targets (`x86_64-windows`,
  `aarch64-windows`) are **not** smoke-tested — only linked. Doing so would
  need `qemu-user-static` (Linux) and Wine (Windows, with no story at all for
  emulating an aarch64 Windows target), which is disproportionate machinery
  for a P3 gap given the native unit + e2e suite already runs on all three
  OSes ahead of the release build. See issue #334.

Accepted, not fixed: a linked-but-never-started binary for these four targets
is the residual risk. If this ever bites, qemu/wine legs can be added to the
`build` matrix following the pattern of the existing `smoke` steps.

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

## Cutting a release (every release)

One command, from a clean `main`:

```sh
# Make the secret key available for the duration (from your password manager).
# Either point at your working copy…
scripts/release.sh 0.24.0

# …or export the key from your password manager to a temp file and pass it:
#   op document get "zcli minisign key" --out ./key.sec   # example
#   scripts/release.sh -s ./key.sec 0.24.0
#   rm -f ./key.sec
```

That drives the whole release and does not return success until zcli.sh serves
the new version (ADR-0033):

1. **Preflight** — tools, credentials, clean tree in sync with origin, version
   not already tagged, `## Unreleased` non-empty. It prints the commits since
   the last tag next to the Unreleased section and asks whether the CHANGELOG
   covers them; that judgment is yours, and this is the last cheap moment to
   make it.
2. **Dispatches the Release workflow**, which bumps the manifests, stages them
   on a scratch branch, and runs the full cross-platform test + build matrix.
3. **Surfaces the one approval.** When the `release` environment gate opens, the
   script rings the terminal bell and prints the URL. Approving promotes the
   staged commit to main and cuts both tags.
4. **Signs the draft** — the ceremony below, run inline.
5. **Waits for the docs deploy**, which fires on `release: published`.
6. **Verifies the end state independently**: both tags resolve to one commit;
   both source archives download, match, and carry consistent manifests/docs/
   changelog metadata; the CLI release has exactly the six expected binaries,
   checksums, and signature; every binary matches its signed checksum; the
   published host binary reports the release version; both site installers match
   the tagged files; the shell installer resolves the just-published CLI release;
   and the live site serves the new version.

**Re-running it is always safe.** Every phase decides what to do from remote
state — is there a tag, a draft, a published release, what does the site serve —
never from local bookkeeping. If your laptop dies mid-signing, run the same
command again and it resumes. Two narrower modes exist for when you need them:

```sh
scripts/release.sh --sign-only 0.24.0     # sign an existing draft, then stop
scripts/release.sh --verify-only 0.23.0   # read-only: did that release land?
```

`--verify-only` checks a release against the *current* live site, so running it
on a superseded version will correctly report that the site has moved on.

Never publish a CLI release draft by hand — that would ship it unsigned.

### The signing ceremony

Both self-verify steps are unconditional and abort on failure:

1. **Signature** — the signature must verify under the committed public key.
   Catches signing with the wrong key. A missing `docs/zcli-minisign.pub` is an
   error (a broken checkout), not a reason to skip.
2. **Tag binding** — the trusted comment must name the tag being signed, as a
   whole whitespace-delimited token. The `-t "zcli $TAG — signed release
   checksums"` argument is what every client checks; a typo there would not
   surface until after publish, when *every* user's install fails closed. This
   catches it while the release is still a draft.

### How a user verifies (for the docs / the paranoid)

```sh
gh release download zcli-v0.20.0 -p 'checksums.txt*'
minisign -Vm checksums.txt -p docs/zcli-minisign.pub
# minisign prints the trusted comment on success — confirm it names the tag you
# downloaded (zcli-v0.20.0). That binding is what makes replaying an older,
# genuinely-signed release under a newer tag fail.
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
