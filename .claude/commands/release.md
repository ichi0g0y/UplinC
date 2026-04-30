---
title: "Release UplinC"
read_only: false
type: "command"
argument-hint: "<version> [--from=bump|rc|prod]"
---

# Release UplinC (/release \<version\>)

## Purpose

Drive the full UplinC release flow end-to-end:

1. **Bump** — Open a PR that bumps `Resources/Info.plist` to the target version.
2. **RC** — After merge, push an RC tag (`v<version>-rcN`); verify the workflow created a prerelease GitHub Release and did **not** bump the homebrew-tap cask.
3. **Prod** — After RC verification, push the production tag (`v<version>`); verify the workflow created the Release and bumped `ichi0g0y/homebrew-tap`'s `Casks/uplinc.rb`.

The command stops at every natural human gate (PR merge, RC verification). It is invoked once per stage; the user replies `next` / `go` between stages, or re-invokes `/release <version>` and picks the stage to resume from.

## Arguments

- `<version>` (required) — Target release version, **no `v` prefix** (e.g. `0.1.13`).
- `--from=bump|rc|prod` (optional) — Start at a specific stage. If omitted, ask the user which stage to begin from based on the detected repo state.

## Pre-flight (always)

1. Run `git status --porcelain`. If non-empty, abort and show the dirty files.
2. `git fetch origin --tags --prune` so subsequent reads see the latest `origin/main` and tags. Do **not** check out `main` — in Conductor workspaces it is held by another worktree and the checkout will fail.
3. Read `CFBundleShortVersionString` and `CFBundleVersion` from `origin/main`'s `Resources/Info.plist`:
   ```
   git show origin/main:Resources/Info.plist > /tmp/uplinc-info.plist
   /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' /tmp/uplinc-info.plist
   /usr/libexec/PlistBuddy -c 'Print :CFBundleVersion'            /tmp/uplinc-info.plist
   ```
   Report both.
4. Probe state to suggest a default stage:
   - If `Info.plist` (on `origin/main`) is still on the old version → suggest **bump**.
   - If it matches `<version>` and an `v<version>-rc*` tag does **not** exist → suggest **rc**.
   - If `v<version>-rc*` tag exists and the matching prerelease is on GitHub → suggest **prod**.
   - If `v<version>` (non-RC) tag already exists → report "already released" and stop.
5. Ask the user which stage to start from (unless `--from` is set).

## Stage 1: Bump

1. `git fetch origin --tags --prune` (skipped if Pre-flight already ran).
2. `git switch -c bump-<version> origin/main` (creates the branch directly off `origin/main` without touching the local `main` ref — works in Conductor workspaces).
3. Bump `Resources/Info.plist`:
   - `CFBundleShortVersionString` → `<version>`.
   - `CFBundleVersion` → current build number + 1.
   - Use `/usr/libexec/PlistBuddy -c 'Set :CFBundleShortVersionString <version>' Resources/Info.plist` and the same for `:CFBundleVersion`.
4. Run `make check` to confirm the plist is still valid.
5. Stage and commit: `📝 [release] Bump version to <version>`. (Single file change; no other edits.)
6. `git push -u origin bump-<version>`.
7. Open the PR with `gh pr create --base main --title "[release] Bump version to <version>" --body "<body>"`. Body should be brief: what changed (Info.plist version + build number) and a one-line reminder that merging triggers the RC stage of `/release`.
8. **STOP.** Report the PR URL. Tell the user to reply `next` (or re-invoke `/release <version>`) once the PR is merged to `main`.

## Stage 2: RC dry-run

1. `git fetch origin --tags --prune` (skipped if Pre-flight already ran).
2. Re-confirm `origin/main`'s `Info.plist` `CFBundleShortVersionString` matches `<version>` using the snippet from Pre-flight step 3. If not, abort — the bump PR likely is not merged yet.
3. Determine RC number `N`: list existing `git tag -l "v<version>-rc*"`, pick the next integer (start at `1`).
4. `git tag v<version>-rc<N> origin/main` and `git push origin v<version>-rc<N>`. Tagging `origin/main` explicitly avoids relying on the workspace's HEAD being on `main`.
5. Find the workflow run: `gh run list --workflow=release.yml --limit 5 --json databaseId,headBranch,status,createdAt`. Match the one whose `headBranch` is the new tag (or the most recent one created after the push).
6. Watch it: `gh run watch <run-id> --exit-status` (blocks until complete; non-zero exit on failure). Report progress concisely.
7. After completion, verify:
   - `gh release view v<version>-rc<N> --json isPrerelease,assets` →  `isPrerelease == true`; assets include `UplinC-<version>.zip` and `UplinC-<version>.zip.sha256`.
   - Tap NOT bumped: `gh api repos/ichi0g0y/homebrew-tap/commits?path=Casks/uplinc.rb --jq '.[0].commit.message'` does **not** mention `<version>`.
8. **STOP.** Report verification results and the prerelease URL. Tell the user to reply `go` (or re-invoke `/release <version> --from=prod`) to proceed, or to investigate if anything failed (see **Recovery** below).

## Stage 3: Production release

1. `git fetch origin --tags --prune` (just to be safe).
2. `git tag v<version> origin/main` and `git push origin v<version>`.
3. Find and watch the workflow run (same approach as Stage 2; use `gh run watch <id> --exit-status`).
4. Verify:
   - `gh release view v<version> --json isPrerelease,assets` → `isPrerelease == false`; assets present.
   - Tap bumped: `gh api repos/ichi0g0y/homebrew-tap/commits?path=Casks/uplinc.rb --jq '.[0].commit.message'` contains `Bump uplinc to <version>`.
5. Report final URLs (Release page, tap commit page).
6. Suggest the smoke test: `brew update && brew upgrade --cask ichi0g0y/tap/uplinc`.
7. (Optional cleanup) Suggest deleting the RC tag and prerelease if the user wants the release page tidy: `gh release delete v<version>-rcN --cleanup-tag --yes` (ask first; do not run automatically).

## Rules

- **NEVER** auto-merge the bump PR. The user merges it after reviewing.
- **NEVER** push directly to `main`. Version bumps always go through PR.
- **NEVER** skip the RC stage unless the user explicitly passes `--from=prod`.
- **ALWAYS** include the workflow run URL when reporting Actions monitoring (so the user can watch in browser too): `gh run view <id> --json url --jq .url`.
- If any verification step fails (Release missing, tap unexpectedly bumped during RC, etc.), STOP and report. Never proceed to the next stage.
- This command does **not** open a dropr task — releases are operational rather than feature work. If the user wants traceability, they can ask explicitly.
- Commit message format follows the repo's convention (English, `emoji [scope] description`).

## Recovery

If a stage fails (workflow run errors, verification mismatch, etc.):

1. **Stop immediately.** Do not push the next stage's tag.
2. Inspect the failed run: `gh run view <run-id> --log-failed` (or open the URL in a browser).
3. If a tag was pushed but no Release was created (e.g. the workflow died at *Verify tag matches Info.plist*), delete the tag so a re-run isn't blocked by it:
   ```
   git push origin :refs/tags/v<version>[-rcN]
   git tag -d   v<version>[-rcN]
   ```
   Confirm with the user before deleting (destructive on the remote).
4. Fix the root cause:
   - **Workflow / CI bug** → open a separate PR against `main` to fix `.github/workflows/release.yml` (or whatever broke). Get it merged.
   - **Wrong Info.plist version** → the bump PR was probably not merged to `main`; merge it and retry.
5. Re-invoke `/release <version> --from=rc` (or `--from=prod`) to resume from the failed stage.
6. If a Release was already created on a bad tag (rare — workflow succeeded but produced wrong artifacts), delete it too: `gh release delete v<version>[-rcN] --cleanup-tag --yes` (ask the user first).

## Example session

```
User:  /release 0.1.13
AI:    Pre-flight: clean. Info.plist 0.1.12 / build 13. Suggest stage: bump. Proceed?
User:  yes
AI:    [bump-0.1.13 branch, Info.plist 0.1.13 / build 14, commit, push, gh pr create]
       PR opened: https://github.com/ichi0g0y/UplinC/pull/N
       Reply `next` once merged.

User:  next
AI:    [pulls main, tags v0.1.13-rc1, pushes, watches Actions]
       RC release: https://github.com/.../releases/tag/v0.1.13-rc1 (prerelease=true)
       Tap unchanged. Reply `go` for production.

User:  go
AI:    [tags v0.1.13, pushes, watches Actions]
       Release: https://github.com/.../releases/tag/v0.1.13
       Tap bumped: https://github.com/ichi0g0y/homebrew-tap/commit/<sha>
       Smoke test: brew update && brew upgrade --cask ichi0g0y/tap/uplinc
```
