# One entry path, one approval, one command for a release

Status: accepted

A release used to be a six-step distributed transaction with no owner: bump the
version, push two tags, approve one gate, approve another, sign on a laptop, and
hope the docs deploy worked. Each step fired into the next and forgot. Nothing
knew what "done" meant, so nothing could report that it had not happened —
zcli.sh served 0.20.0 for three weeks while 0.21.0, 0.22.0 and 0.23.0 shipped,
with nothing red anywhere.

This ADR records three decisions that make a release one supervised sequence:
**dispatch is the only entry path**, **`finalize` carries the only approval**,
and **`scripts/release.sh` owns the transaction end to end**. It amends the
process around ADR-0009 and ADR-0023; it does not change the trust model either
one establishes.

## The constraint that determines the shape

ADR-0023 puts the signing key in the maintainer's password manager, deliberately
nowhere near CI. That decision is load-bearing and unchanged here, but it has an
architectural consequence worth stating outright: **there is an irreducible step
on a human's laptop, so the "one command" cannot be a GitHub button.**

The old design had CI orchestrate, hand off to the laptop in the middle for
signing, then hand back to CI for the docs deploy. That middle handoff is where
atomicity died — no participant spanned the whole transaction, so no participant
could verify it completed. The laptop is the only party present from start to
finish. It should drive.

This is not a true atomic transaction across GitHub Releases and Cloudflare
Pages, and cannot be. What is achievable, and what "atomic" means here: **one
command that does not return success until zcli.sh serves the new version, and
is safe to re-run at any point.**

## Dispatch is the only entry path

The `on: push: tags` trigger is removed. It was documented as a fallback and
became the path actually used, because it interacted badly with everything else:

- It required the version bump merged to main **first**, which then made
  `workflow_dispatch` unusable for that version — dispatch would try to bump
  again. Choosing the fallback was therefore irreversible, and nothing said so.
- The tag could point at a commit the CHANGELOG did not describe. For 0.23.0 it
  did: three PRs merged between the release commit and the tag push. Caught by
  eye, not by a check.
- Two tags meant two runs, two approvals, and two chances to forget one.

With dispatch as the only path, CI promotes the CHANGELOG's `## Unreleased`
section and cuts both tags in the **same commit**, so the tag and the release
notes cannot describe different trees. The class of bug is gone rather than
guarded against.

Losing the break-glass path is the real cost, and it is small: a failed dispatch
leaves main and the tag namespace untouched by design (the staging-branch
design, #301), so the remedy is to fix and re-run. If Actions is down, neither
path works.

## `finalize` carries the only approval

All three publishing jobs used to declare `environment: release`. That was an
artifact of the two entry paths — the tag-push path skipped `finalize`, so no
single job was present on both paths to hold the gate. Removing that trigger
makes `finalize` always present, and it is the right place:

- It is **the point of no return.** Everything before it is a disposable scratch
  branch; everything after is a consequence of the tags it cuts.
- `release` publishes a **draft**. A draft is not public, so gating it protected
  nothing — and it cost 0.23.0 an eight-hour stall between a green build and the
  draft being created. The real gate on the CLI release is the signing ceremony.
- `library-release` does publish immediately, and is the only job that makes
  something public with no human in the loop. But it cannot run without the tag
  `finalize` creates, so the `finalize` approval already dominates it.

Two approvals become one, and it lands after test and build are green — when
there is actually something to approve.

The runtime assertion from #397, which refuses to publish if the `release`
environment has lost its required-reviewers rule, is **kept**. An environment
gate is a repo-settings fact the YAML cannot see, and 0.20.0 shipped through an
inert one. It now lives in one job instead of three.

## `scripts/release.sh` owns the transaction

One command, one approval surfaced inside it, blocking until the site is live:
preflight, dispatch, wait for the gate, wait for the draft, sign it, publish,
wait for the docs deploy, then **independently verify** the end state — zcli.sh
serves the new version, `zcli.sh/install.sh` matches the repo, the release
carries its signature and that signature verifies against the pinned key.

`scripts/sign-release.sh` is absorbed into it, with `--sign-only` kept as the
recovery path. Two scripts is how the ceremony became a thing to remember.

**Resumability is the design principle, not a feature.** The script derives its
position from observable remote state — does the tag exist, is there a draft, is
it published, what does the site serve — never from local bookkeeping. Re-running
after any failure is therefore always safe and always converges. That property,
not a distributed commit protocol, is what makes the process feel atomic when a
step fails.

## Consequences

- The website is built in CI (`ci.yml`'s `website` job) on any PR touching an
  input, using the same pinned Zine as the deploy. `CHANGELOG.md` is a build
  input — the changelog page is generated from it — so a repo-relative markdown
  link in a release entry breaks the deploy. That is how the 0.23.0 deploy died,
  and it is now a red check instead of a post-release incident.
- The docs deploy asserts the live site serves what it just built, so a deploy
  that does not land has somewhere to fail.
- `docs/RELEASE-SIGNING.md` keeps the key-custody ceremony (which is the actual
  security work) and defers the per-release mechanics to `scripts/release.sh`.

## Considered and rejected

- **Keep the tag-push trigger as a documented fallback.** Rejected: it is what
  produced every ordering problem above, and its existence is what forced the
  three-gate structure. A fallback used by default is not a fallback.
- **Have CI wait for the signature.** A job polling for `checksums.txt.minisig`
  to appear would keep CI as orchestrator, but it burns runner minutes for hours
  and removes no human steps.
- **Sign in CI, or on a self-hosted runner.** Puts the key next to the release
  credentials — the "ceremony without security" case ADR-0009 named and ADR-0023
  rejected. Unchanged.
- **Remove the approval entirely**, treating the signing passphrase prompt as
  the human checkpoint. Tempting, since `library-release` is the only unsigned
  publish — but that is precisely the job with no other human in its path, and
  #397 is a standing reminder that an inert gate is worth catching. One real
  gate beats zero.
