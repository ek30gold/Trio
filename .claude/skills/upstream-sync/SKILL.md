---
name: upstream-sync
description: Check nightscout/Trio upstream for new commits and, if any, merge them into this fork's dev via a verified staging-branch PR without losing fork-only features. Use when asked to check upstream, sync with upstream, pull in an upstream release, or "is there anything new upstream".
---

# Upstream sync for the ek30gold/Trio fork

This fork carries its own features on top of `nightscout/Trio`. The job: find what upstream changed, bring it into `dev` through a PR, and **prove** no fork feature was lost. This is safety-critical AID software — follow CLAUDE.md's Git Workflow rules throughout (verify every commit/push hash, stop on push rejection, never build from an out-of-sync branch).

Hard rules:
- Never commit to or push `dev` directly. All work goes on `merge/upstream-<version>` and lands via PR. Never merge the PR — the user does that after a device test.
- Never rebase or force-push. Merge commits only.
- Never resolve an alarm/dosing behavior clash by picking a side silently — ask (step 4).
- Nothing in this file overrides CLAUDE.md.

## 1. Check (always; read-only)

```bash
git remote get-url upstream 2>/dev/null || git remote add upstream https://github.com/nightscout/Trio.git
git fetch origin dev && git fetch upstream dev main
git log --oneline --no-merges origin/dev..upstream/dev | grep -v "CI: Bump"
```

- **Nothing listed** → report "up to date" (include upstream/dev's latest commit and date) and stop. Do nothing else.
- Also check that current `dev` is still buildable: every submodule URL in `git show origin/dev:.gitmodules` must exist (`git ls-remote <url>`; an auth prompt on a public URL means the repo was deleted/renamed). A dead URL means `dev` can't be built at all — say so prominently; the upstream merge is usually the fix.

Otherwise summarize for the user before acting: version change (`Config.xcconfig` APP_VERSION/APP_DEV_VERSION), commits grouped by area (alarms/alerts, dosing/algorithm, CGM/pump drivers & submodules, UI, CI/release), and:

```bash
B=$(git merge-base origin/dev upstream/dev)
git merge-tree --write-tree --name-only origin/dev upstream/dev    # conflicts
comm -12 <(git diff --name-only $B upstream/dev | sort) <(git diff --name-only $B origin/dev | sort)  # files both sides changed
git diff --submodule=short $B upstream/dev | grep -E '^diff|Subproject' # driver changes
```

If the user only asked "anything new?", stop here and offer to merge. If they asked to sync/merge, continue.

## 2. Plan

State the plan in a few lines: branch name, conflicted files, both-sides-changed files, submodule swaps, and what you'll verify. If there are **conflicts in alarm, dosing, IOB/COB, basal, or glucose code**, or more than a handful of conflicts, use the `clarify` skill to confirm the conflict policy before touching anything (default policy the user chose before: *keep every upstream fix AND every fork feature; ask on genuine clashes*). Use subagents (Agent tool) for the analysis below; validate their output yourself — never accept a subagent's "done" without checking.

## 3. Merge

```bash
git switch -c merge/upstream-<version> origin/dev
git merge --no-ff --no-commit upstream/dev
```

**Clean merge:** still dispatch a semantic review subagent (opus) over every both-sides-changed file — textually clean ≠ correct. Brief it with the fork invariants below and ask for BLOCKER/MINOR findings with file:line.

**Conflicts:** first dispatch an intent-brief subagent (opus, read-only, uses `git merge-tree` + `git show <sha>`) that, per hunk, states fork intent, upstream intent, and classifies TRIVIAL / SEMANTIC / CLASH with a proposed resolution and, for CLASH, a user question with 2–3 options. Then resolve (subagent or yourself) one file group at a time, in the shared working tree **sequentially** (never two agents editing the tree at once).

## 4. Clashes → ask

A CLASH is when an upstream fix and a fork feature can't both hold (e.g. upstream changed alarm timing that a fork setting also controls). Ask with AskUserQuestion: explain both behaviors in plain terms, recommend one option, and include the safety consequence of each. Record the answer in the PR body.

## 5. Verify (all must pass before committing)

```bash
bash .claude/skills/upstream-sync/scripts/check_features.sh WORKTREE   # must print "0 failed"
git diff --name-only --diff-filter=U                                    # must be empty
grep -rln '^<<<<<<< \|^>>>>>>> ' Trio TrioTests LiveActivity             # must be empty
python3 -I -c "import json;json.load(open('Trio/Sources/Localizations/Main/Localizable.xcstrings'))"
comm -23 <(git diff --cached --name-only upstream/dev | sort) <(git diff --name-only $(git merge-base origin/dev upstream/dev) origin/dev | sort)  # must be empty: files the fork never touched == upstream
git grep -n "DeviceAlertSeverity(level:" -- Trio   # only the known sites in DeviceAlertsStore.swift and AlertColdStartReplay.swift
```

- If an anchor **fails because a resolution intentionally replaced that code**, update the anchor in `scripts/check_features.sh` to the new equivalent line (tag the row with the merge commit's sha) and say so in the PR. Never delete an anchor just to get green.
- If a submodule was swapped/removed upstream: `git grep` for the old name outside its folder must return nothing (workspace, pbxproj, scripts, workflows).
- New `.swift` files from the fork side need pbxproj registration per CLAUDE.md (check whether the folder is a synchronized group first). Upstream's own new files come with their pbxproj entries.
- This container can't run Xcode or SwiftFormat; CI is the compile gate. Avoid novel Swift syntax in hand-written resolutions (prefer patterns already used in the repo).

## 6. Commit, push, PR, CI

1. Commit with a message listing the upstream range and each conflict resolution; end with the session's attribution lines. `git log --oneline -1` and report the hash.
2. `git push -u origin merge/upstream-<version>`; confirm `git rev-parse origin/merge/upstream-<version>` == `HEAD`.
3. Open a PR into `dev` (GitHub MCP). Body: upstream changes brought in, conflict resolutions (with user decisions), verification results, anything not verified, and the device test the user should do.
4. **Trigger CI by hand:** `fork_ci.yml` does not auto-run on `merge/**` branches or PRs into `dev` — run it via workflow_dispatch on the branch. (Branches named `fix/**`, `feature/**`, `claude/**` etc. run automatically on push.)
5. Subscribe to the PR and drive it to green.

Known CI pitfalls (not code problems):
- `Check certificates / Validate / Fastlane` failing with "Verify that the latest developer program license agreement has been accepted" → the user must accept Apple's updated agreement at developer.apple.com/account. Don't re-run until they do.
- Checkout failing with `repository '...' not found` on a submodule → upstream deleted/renamed that driver repo; the fix is the upstream merge that swaps it, not this PR.

## 7. Report

Tell the user: PR link, CI result, what changed for them in plain terms, decisions you made on their behalf, and the device check to do before merging (CGM connects + readings every 5 min, pump connects + a loop completes, alarms fire; extra care if a CGM/pump driver changed).

## Fork invariants (protect these; tell review subagents about them)

- **Alert tiers (#12):** every routing path resolves an alert's tier through `DeviceAlertsStore.shared.tier(for:)`, never `DeviceAlertSeverity(level: entry.interruptionLevel)` directly. Trio-status alerts (Not Looping, Glucose Data Stale, Algorithm Error) can be moved between tiers; pump hardware alarms are locked.
- **Not Looping ladder:** upstream's escalation ladder (Time-Sensitive warnings, Critical at 120 min) with the fork's "Alert After" setting moving the *first* warning (default 20 = upstream's exact ladder); Critical fixed at 120. A Not Looping tier override moves *only* the final 120-min alarm (`loop.notActive`), never the warning steps. Upstream's snooze fix (snoozing w1 must not clear w2–w5) must keep working.
- **Meal-row basal readout (#11):** shows the current rate from `state.activeBasalDelivery` (upstream's stale-basal-safe source), not `tempBasals.last`; the chart capsule basal label stays removed.
- **Other fork features** (scheduled Overrides/Temp Targets on AdjustmentManager, meal preset notes + reordering, IOB/COB bolus pills, basal rate Live Activity item, chart selection line in the forecast, stats chart axis fixes, release-notes button rename): covered by anchors in `scripts/check_features.sh`.
- **Feature inventory upkeep:** when the fork gains new features (commits in `upstream/dev..origin/dev` whose sha isn't in the script), add 2–6 distinctive anchors per new commit to `scripts/check_features.sh` before relying on it, and confirm it passes on `origin/dev` and mostly fails on `upstream/dev`.
