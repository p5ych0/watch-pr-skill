# Decision: a same-UID process substituting the session's work directory is an accepted limit

**Date:** 2026-09-03
**Status:** accepted
**Decided by:** the repository operator, after the measurement below and Codex's review of PR #275
**Closes:** #272

Every handoff resolves `$RB_SETUP_DIR/work` by NAME at each step — the driver's
head read, the writes, the emptyings, and the `gh --body-file` posts. A same-UID
process that renames `work` away and puts a symlink, or a fresh directory, at that
name redirects the operation. This is accepted rather than fixed, and this record is
what a reviewer should be pointed at when it is raised again.

## What the impact actually is, and what it is not

The measured impact is that the driver's post-gate head CONFIRMATION accepts a forged
value from the substituted parent: `rb_handoff_is_sha` follows the substituted `work`
and returns 0 for a forged 40-hex, so the driver treats a head as gated and resolves
the round's threads, and `CODEX_SHA` — which the driver reads from the same
`work/head.txt` (`SKILL.md` reads it at `9<"$HEAD_FILE"`) — carries a forged value
forward. That is what the fixture demonstrates.

It is NOT demonstrated that this completes a MERGE on a forged head, and the earlier
"gate bypass" framing overstated it. `pr-merge-gate.sh` never reads the work directory:
it checks `CODEX_SHA` against the durable signoff record and against the reviewer's
actual VERDICT on that sha (`pr-review-state.sh verdict`), and pins the merge with
`--match-head-commit`. A forged `CODEX_SHA` that is not a commit the reviewer actually
signed clean is refused there, fail-closed. So the remaining barrier to a completed
merge is independent of the work directory, and the accepted impact is the corrupted
confirmation and the forged `CODEX_SHA`, not a merge.

## Why it is accepted rather than fixed

A fix was attempted in PR #275 and closed. It recorded the directory's `(dev, ino)`
in a `work.id` file, had the driver hold that pair, and made the head read verify
it. Codex's review proved it does not close the forgery, on two independent grounds:

- **A file-based identity is substitutable.** `work.id` is a regular file the same
  UID can replace in the setup→driver-read window with a prepared directory's
  `(dev, ino)`, so the driver ends up holding the attacker's identity and later
  accepts the attacker's head.
- **`(dev, ino)` is not a durable capability.** Inode numbers are reused by ext4
  and xfs after a directory is removed. A racer can delete the gated `work` after
  the gate, recreate a directory until the freed inode is reused, and drop a forged
  head — an ABA against the recorded pair, needing no tight window.

The only sound anchor is a **held file descriptor** to `work`, kept open for the
whole session and inherited by the child helpers, so the inode is pinned (ABA-proof)
and never re-resolved by name. The driver cannot acquire one safely:

- bash cannot open a directory redirection with `O_NOFOLLOW`/`O_NONBLOCK`, so
  `exec {fd}<"$work"` follows a symlinked `work` and blocks on a FIFO planted at the
  name — an unbounded hang in the driving shell;
- the mac CI runs bash 3.2.57, which has no `{var}<` auto-fd allocation;
- a helper that opens the directory correctly cannot hand its descriptor back to the
  parent, and a long-lived descriptor-holder is the daemon v2 does not run.

## What bounds the limit

The attacker is a **same-UID process racing the running session**, which means an
attacker who already has arbitrary code execution as the operator's user. Such an
attacker can already: edit the very commits under review, read `~/.config/gh` and
merge pull requests directly, rewrite the driver's own `SKILL.md` and scripts, or
change the checkout's `origin`. Forging a review head through a work-directory race
is strictly weaker than what they already hold, so closing this vector adds no real
security against a realistic attacker. A different-UID process cannot reach the
work directory at all — it is created mode 700 under a parent the session owns.

It is the same SAME-UID class as two of the adjacent records —
`docs/decisions/2026-08-29-setup-leaf-cleanup.md` and
`docs/decisions/2026-09-01-origin-cleanup-races.md`, both races in the session's own
working area that only a same-UID process can reach — differing from them in
CONSEQUENCE: a forged head rather than litter, which the bounding argument above is
why it is nonetheless accepted. It is NOT the same as
`docs/decisions/2026-08-26-transport-candidate-in-argv.md`, which is a different
threat model: the transport candidate is published in argv, so ANY local account can
observe and squat it, and its measured consequence is a bounded setup denial of
service, not a forged head. This record's race is reachable only by the same UID,
because `work` is created mode 700 under a parent the session owns.

## The measurement

`test-writelib.sh` stages the race against the real `rb_handoff_is_sha`, and the two
heads are DELIBERATELY DISTINGUISHABLE by status. It writes an INVALID sentinel
(`not-a-commit-id`) into the original `work/head.txt`, renames `work` away, and puts a
directory holding a VALID forged 40-hex head at the name. The read follows the
substituted parent, so it reads the valid forged head and returns 0 — the accepted
limit. Because only the substituted file is a valid commit id, a status of 0 proves
the substituted inode was read: an anchored read that reached the original inode would
read the invalid sentinel and return non-zero. The case is written to PIN the status,
so if a later change anchors the read to the directory's identity and the forgery
stops working, the case fails and this record is revisited rather than silently
outliving the limit it accepts — which is the standard this repository holds every
accepted record to.
