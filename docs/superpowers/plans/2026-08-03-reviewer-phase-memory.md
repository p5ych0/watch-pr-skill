# Reviewer-Phase Memory (S1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop Codex re-reviewing Copilot-fix commits after it has already signed off, and make the Copilot pass impossible to skip by omission.

**Architecture:** A clean Codex signoff writes a per-PR marker holding the signed-off SHA. Auto-enqueue consults it: a head reachable from that SHA by commits that *all* carry a `Review-Phase: copilot` trailer is held; anything else invalidates the marker and reviews normally. Separately, `review-bus-copilot.sh` gains a `gate` subcommand that the skill's merge block must pass, so declining Copilot becomes an explicit recorded act rather than an omission.

**Tech Stack:** Bash (strict mode), `jq`, `gh`, `git`. No new dependencies.

Spec: `docs/superpowers/specs/2026-08-03-self-review-docs-and-phase-memory-design.md` § S1.

## Global Constraints

- Follow `CLAUDE.md` — it is now canonical and was merged in #4. In particular: the strict-mode table (do **not** add `-e` to `review-bus-copilot.sh`), fail-closed by outcome (propagate non-zero *or* emit a sentinel every caller rejects), explicit `return 0` on every intentional no-op, and no hard-coded owner/repo identity.
- **Fail-closed direction for this feature is to REVIEW, not to hold.** A hold means Codex never looks at a commit. Any uncertainty — unreadable marker, failed `gh compare`, malformed trailer — must fall through to a normal review.
- The trailer is exactly `Review-Phase: copilot` on its own line in the commit message.
- Tests are self-contained: throwaway git repos, stubbed `gh`, no network.
- Bump **both** `.claude-plugin/plugin.json` and `.codex-plugin/plugin.json` to 1.0.12 plus a CHANGELOG entry.

---

### Task 1: Record the clean signoff and surface the phase

**Files:**
- Modify: `skills/watch-prs/scripts/review-bus-codex-watcher.sh` (`write_response` at `:310`, the zero-findings branch at `:1065-1075`)
- Modify: `skills/watch-prs/scripts/review-bus-response-monitor.sh:153` (handoff line)
- Test: `skills/watch-prs/scripts/test-review-bus-phase.sh` (create)

**Interfaces:**
- Produces: `$BUS_DIR/.codex-clean-<pr>` containing the full 40-char signoff SHA; `next_phase: "copilot"` in the response JSON. Task 2 reads the marker file; the monitor reads the field.
- `write_response` gains an **optional 8th positional** `next_phase`. Existing 7-arg call sites keep working and omit the field.

- [ ] **Step 1: Write the failing test**

Create `skills/watch-prs/scripts/test-review-bus-phase.sh` with the marker/response assertions (full content in Task 2's step 1, which extends the same file — write the file once with both sections).

- [ ] **Step 2: Add the optional `next_phase` argument to `write_response`**

```bash
write_response() {
    local resp="$1" pr="$2" sha="$3" status="$4" findings="$5" summary="$6" log="$7"
    local next_phase="${8:-}"

    jq -n \
        --argjson pr "$pr" \
        --arg sha "$sha" \
        --arg completed_at "$(date -u +%FT%TZ)" \
        --arg status "$status" \
        --argjson findings_count "$findings" \
        --arg summary "$summary" \
        --arg log "$log" \
        --arg next_phase "$next_phase" \
        '{
          pr: $pr,
          sha: $sha,
          completed_at: $completed_at,
          reviewer: "codex",
          status: $status,
          findings_count: $findings_count,
          summary: $summary,
          log: $log
        } + (if $next_phase == "" then {} else {next_phase: $next_phase} end)' > "${resp}.tmp"
    mv "${resp}.tmp" "$resp"
}
```

- [ ] **Step 3: Write the marker on a successful signoff**

In the zero-findings branch, after `post_clean_signoff` succeeds:

```bash
        if clean_event="$(post_clean_signoff "$pr" "$full_sha" "$sha" "$summary")"; then
            status="approved"
            summary="No actionable findings on sha=$sha; clean review signoff posted as $clean_event."
            next_phase="copilot"
            # Record WHICH sha earned the signoff. Task 2 measures the Copilot
            # phase from here. A failed write is not fatal: without the marker
            # auto-enqueue simply reviews the next head, which is the safe
            # direction — a hold would mean a commit is never reviewed.
            if ! printf '%s\n' "$full_sha" > "$BUS_DIR/.codex-clean-${pr}.tmp" \
                 || ! mv "$BUS_DIR/.codex-clean-${pr}.tmp" "$BUS_DIR/.codex-clean-${pr}"; then
                echo "CODEX_CLEAN_MARKER_FAILED pr=$pr sha=$sha" >&2
                rm -f "$BUS_DIR/.codex-clean-${pr}.tmp"
            fi
        else
```

Declare `next_phase` in the function's `local` list (initialise to empty) and pass it as the 8th argument to the `write_response` call at the end of `process_review`.

- [ ] **Step 4: Surface it in the handoff line**

In `review-bus-response-monitor.sh:153`, append the field so the notification states the obligation:

```bash
          "\($prefix)_REVIEW pr=\(.pr) sha=\(.sha) status=\(.status) findings=\(.findings_count) reviewer=\(.reviewer)\(if .next_phase then " next_phase=\(.next_phase)" else "" end) summary=\(.summary // "" | gsub("[\n\r]"; " ") | .[0:200]) resp=" + $path
```

- [ ] **Step 5: Run the tests**

```bash
cd skills/watch-prs/scripts && bash test-review-bus-phase.sh && bash test-review-bus-monitor.sh
```

Expected: `RESULT: PASS` from both.

- [ ] **Step 6: Commit**

```bash
git add skills/watch-prs/scripts/review-bus-codex-watcher.sh skills/watch-prs/scripts/review-bus-response-monitor.sh skills/watch-prs/scripts/test-review-bus-phase.sh
git commit -m "feat(watcher): record the clean signoff sha and surface next_phase"
```

---

### Task 2: Hold auto-enqueue during the Copilot phase

**Files:**
- Modify: `skills/watch-prs/scripts/review-bus-codex-watcher.sh` (`write_auto_request`)
- Test: `skills/watch-prs/scripts/test-review-bus-phase.sh` (extend)

**Interfaces:**
- Consumes: `$BUS_DIR/.codex-clean-<pr>` from Task 1.
- Produces: `CODEX_AUTO_SKIP pr=N reason=copilot_phase`, and marker deletion on invalidation.

- [ ] **Step 1: Write the failing test**

Cover four cases: every commit since the marker carries the trailer → held, no request; one commit lacks it → marker deleted and request written; `gh compare` fails → request written (fail-closed to review); no marker → unchanged behaviour.

- [ ] **Step 2: Add the phase check**

Insert in `write_auto_request` after the terminal-response check and before the round claim:

```bash
    # Copilot phase. Once Codex has signed off clean, commits that exist ONLY to
    # address Copilot findings should not pull Codex back in — SKILL.md says it
    # does not gate, and re-reviewing burns a round and fires a notification.
    # The trailer is the key rather than a commit-subject prefix, because
    # subject-prefix counting already failed in this repo (CHANGELOG 1.0.10).
    #
    # Every uncertainty here falls through to a REVIEW. A wrong hold means a
    # commit is never reviewed; a wrong review costs one redundant pass.
    local clean_marker clean_sha msgs
    clean_marker="$BUS_DIR/.codex-clean-${pr}"
    if [ -f "$clean_marker" ]; then
        clean_sha="$(tr -cd '0-9a-f' < "$clean_marker" 2>/dev/null || true)"
        if [ ${#clean_sha} -eq 40 ] && [ "$clean_sha" != "$head_oid" ]; then
            if msgs="$(gh api "repos/$REPO_SLUG/compare/${clean_sha}...${head_oid}" \
                        --jq '.commits[].commit.message' 2>/dev/null)" && [ -n "$msgs" ]; then
                if ! printf '%s\n' "$msgs" | grep -qvxF 'Review-Phase: copilot' \
                   && printf '%s\n' "$msgs" | grep -qxF 'Review-Phase: copilot'; then
                    echo "CODEX_AUTO_SKIP pr=$pr reason=copilot_phase clean_sha=${clean_sha:0:7}"
                    return 0
                fi
            fi
            rm -f "$clean_marker"
        fi
    fi
```

**Note for the implementer:** the two-`grep` construction above is wrong — it compares whole lines against the trailer, so any ordinary message line fails it. Replace it with a per-commit check: split `.commits[]` and require each commit's message to contain a `Review-Phase: copilot` line. Use

```bash
        total="$(gh api "repos/$REPO_SLUG/compare/${clean_sha}...${head_oid}" --jq '.commits | length' 2>/dev/null || echo "")"
        tagged="$(gh api "repos/$REPO_SLUG/compare/${clean_sha}...${head_oid}" \
                   --jq '[.commits[] | select(.commit.message | test("(^|\n)Review-Phase: copilot(\n|$)"))] | length' 2>/dev/null || echo "")"
```

and hold only when `total` and `tagged` are both non-empty integers, `total -gt 0`, and `total -eq tagged`.

- [ ] **Step 3: Run the tests**

```bash
cd skills/watch-prs/scripts && bash test-review-bus-phase.sh
```

- [ ] **Step 4: Commit**

```bash
git commit -am "feat(watcher): hold auto-enqueue while a PR is in its Copilot phase"
```

---

### Task 3: The Copilot merge gate

**Files:**
- Modify: `skills/watch-prs/scripts/review-bus-copilot.sh` (new `gate` and `decline` subcommands)
- Modify: `skills/watch-prs/SKILL.md` (merge block)
- Test: `skills/watch-prs/scripts/test-review-bus-copilot.sh` (extend)

**Interfaces:**
- Produces: `gate <PR>` exiting 0 (clean Copilot review on the current head, or a recorded decline for that head), 1 (neither), 2 (fetch failure — callers fail closed). `decline <PR>` records `$BUS/.copilot-declined-<pr>` containing the head SHA.

- [ ] **Step 1: Write the failing tests** — gate returns 1 with no review, 0 with a clean head review, 0 after `decline`, 1 when the head moves past a decline, 2 on fetch failure.

- [ ] **Step 2: Implement `decline` and `gate`.** Reuse `head_review_findings` and the existing head resolution. A decline is head-scoped: store the SHA and compare, so a push after declining re-opens the question.

- [ ] **Step 3: Wire it into `SKILL.md`'s merge block** as a hard gate before `gh pr merge`, with the exit codes spelled out.

- [ ] **Step 4: Run tests, commit.**

---

### Task 4: Document the trailer and release

**Files:**
- Modify: `CLAUDE.md` (§ Stating the task), `README.md`, `CHANGELOG.md`, both plugin manifests

- [ ] **Step 1: Document the `Review-Phase: copilot` trailer** in `CLAUDE.md` as an authoring rule: commits made to address Copilot findings carry it; a missing trailer costs one redundant Codex review, never a missed one.
- [ ] **Step 2: README** — describe the phase behaviour and the merge gate under the Copilot section.
- [ ] **Step 3: Bump both manifests to 1.0.12 + CHANGELOG entry.**
- [ ] **Step 4: Full suite, commit, push, open PR.**

## Self-Review

**Spec coverage:** recording → Task 1; invalidation → Task 2; enforcement → Task 3; trailer documentation and release → Task 4.

**Deliberate deviation from the spec:** the spec says a decline is recorded at `$BUS/.copilot-declined-<pr>` without saying whether it is head-scoped. This plan makes it head-scoped, because an unscoped decline would silently authorise merging code pushed *after* the operator declined.

**Known risk:** Task 2's hold depends on `gh api compare`, which is a network call inside the watcher's poll loop. It runs only while a clean marker exists and the head has moved, so it is not per-poll for ordinary PRs. If that proves noisy, cache by `<clean_sha>..<head_oid>` — not done up front, to avoid unrequested machinery.
