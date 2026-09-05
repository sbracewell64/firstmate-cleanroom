#!/usr/bin/env bash
# Tests for bin/fm-review-diff.sh: when a task has an open PR recorded in meta,
# the review diff must compare the authoritative base against a freshly fetched
# PR head, not a stale local branch or a stale recorded pr_head= left behind
# after no-mistakes fix rounds push to the PR.
#
# Matrix:
#   (a) pr= + reachable pr_head=, no remote pull ref -> offline fallback to recorded SHA
#   (b) pr= without pr_head= -> fetch refs/pull/<n>/head and diff that
#   (c) pr= absent -> unchanged worktree-branch diff
#   (d) pr= present but PR head unreachable -> fallback to local branch + warning
#   (e) pr= + STALE recorded pr_head= + newer remote pull head -> must use fetched head
#       (this is the class that bit reviewers holding merges over "missing" fixes)
#
# Hardening (slice S3), all exercised through the executable only:
#   (f) header pins base, compare, and merge-base to exact commit SHAs
#   (g) a renamed file shows old + new path under --stat and full diff
#   (h) a deleted file is listed and counted in the changed-path summary
#   (i) malformed meta or arguments refuse nonzero, naming the bad field
#   (j) every pre-existing refusal still refuses
#   (k) an unobservable PR head prints a stdout could-not-observe label that the
#       observed-PR-head path never prints
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

REVIEW_DIFF="$ROOT/bin/fm-review-diff.sh"
TMP_ROOT=$(fm_test_tmproot fm-review-diff-tests)

make_case() {
  local name=$1 case_dir
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir/state"

  git init -q --bare "$case_dir/origin.git"
  git -C "$case_dir/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$case_dir/origin.git" "$case_dir/_seed" 2>/dev/null
  printf 'base\n' > "$case_dir/_seed/feature.txt"
  printf 'second\n' > "$case_dir/_seed/second.txt"
  git -C "$case_dir/_seed" add feature.txt second.txt
  git -C "$case_dir/_seed" -c user.email=t@t -c user.name=t commit -qm "origin baseline"
  git -C "$case_dir/_seed" push -q origin main
  rm -rf "$case_dir/_seed"

  git clone -q "$case_dir/origin.git" "$case_dir/project"
  git -C "$case_dir/project" remote set-head origin main 2>/dev/null || true
  git -C "$case_dir/project" worktree add -q -b fm/task-x1 "$case_dir/wt" main

  touch "$case_dir/state/.last-watcher-beat"
  printf '%s\n' "$case_dir"
}

write_task_meta() {
  local case_dir=$1
  shift
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "$@"
}

stale_and_pr_commits() {
  local case_dir=$1
  printf 'stale-local\n' > "$case_dir/wt/feature.txt"
  git -C "$case_dir/wt" add feature.txt
  git -C "$case_dir/wt" commit -qm "stale local branch"

  git -C "$case_dir/wt" checkout -q -b pr-head-tmp
  printf 'pr-fixed\n' > "$case_dir/wt/feature.txt"
  git -C "$case_dir/wt" add feature.txt
  git -C "$case_dir/wt" commit -qm "pipeline fix on PR"
  PR_SHA=$(git -C "$case_dir/wt" rev-parse HEAD)

  git -C "$case_dir/wt" checkout -q fm/task-x1
}

run_review_diff() {
  local case_dir=$1
  shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
    "$REVIEW_DIFF" "$@"
}

test_pr_meta_uses_pr_head_not_stale_local() {
  local case_dir out
  case_dir=$(make_case pr-head-sha)
  stale_and_pr_commits "$case_dir"
  # No remote pull ref: fetch fails, recorded pr_head is the offline fallback.
  write_task_meta "$case_dir" \
    "pr=https://github.com/example/repo/pull/9" \
    "pr_head=$PR_SHA"

  out=$(run_review_diff "$case_dir" task-x1 2> "$case_dir/stderr")

  assert_contains "$out" '+pr-fixed' "pr-head-sha: diff should show the PR head content"
  assert_not_contains "$out" 'stale-local' "pr-head-sha: diff must not use the stale local branch"
  assert_not_contains "$(cat "$case_dir/stderr")" 'warning: PR head unavailable' \
    "pr-head-sha: should not warn when recorded pr_head is reachable offline"
  assert_contains "$out" 'COULD NOT OBSERVE LIVE PR HEAD' \
    "pr-head-sha: recorded-head fallback must label the unobserved live head on stdout"
  assert_contains "$out" "diff compare: PR 9 recorded pr_head= $PR_SHA" \
    "pr-head-sha: header must name the recorded head and its exact SHA"
  pass "fm-review-diff falls back to recorded pr_head when pull head cannot be fetched"
}

test_stale_recorded_pr_head_loses_to_fetched_pull_head() {
  local case_dir out stale_sha
  case_dir=$(make_case stale-recorded)
  stale_and_pr_commits "$case_dir"
  stale_sha=$(git -C "$case_dir/wt" rev-parse fm/task-x1)
  # Remote PR head is newer (pipeline fix); meta still points at the older local tip.
  git -C "$case_dir/wt" push -q origin "pr-head-tmp:refs/pull/9/head"
  write_task_meta "$case_dir" \
    "pr=https://github.com/example/repo/pull/9" \
    "pr_head=$stale_sha"

  out=$(run_review_diff "$case_dir" task-x1 2> "$case_dir/stderr")

  assert_contains "$out" '+pr-fixed' \
    "stale-recorded: diff must show the fetched PR head, not the recorded stale SHA"
  assert_not_contains "$out" 'stale-local' \
    "stale-recorded: diff must not use the stale local/recorded content"
  assert_not_contains "$(cat "$case_dir/stderr")" 'warning: PR head unavailable' \
    "stale-recorded: fetch of refs/pull/<n>/head should succeed"
  # Pre-fix behavior preferred reachable recorded pr_head= and would show stale-local.
  [ "$stale_sha" != "$PR_SHA" ] || fail "stale-recorded: fixture did not diverge recorded vs PR head"
  pass "fm-review-diff prefers freshly fetched PR head over a stale recorded pr_head="
}

test_pr_meta_fetches_pull_head_without_recorded_sha() {
  local case_dir out
  case_dir=$(make_case pr-fetch)
  stale_and_pr_commits "$case_dir"
  git -C "$case_dir/wt" push -q origin "pr-head-tmp:refs/pull/9/head"
  write_task_meta "$case_dir" "pr=https://github.com/example/repo/pull/9"

  out=$(run_review_diff "$case_dir" task-x1 2> "$case_dir/stderr")

  assert_contains "$out" '+pr-fixed' "pr-fetch: diff should use fetched PR head"
  assert_not_contains "$out" 'stale-local' "pr-fetch: diff must not use the stale local branch"
  assert_not_contains "$(cat "$case_dir/stderr")" 'warning: PR head unavailable' \
    "pr-fetch: should not warn when fetch succeeds"
  assert_not_contains "$out" 'COULD NOT OBSERVE' \
    "pr-fetch: observed-PR-head path must not print a could-not-observe label"
  assert_contains "$out" "diff compare: PR 9 head (fetched refs/pull/9/head) $PR_SHA" \
    "pr-fetch: header must name the fetched PR head and its exact SHA"
  pass "fm-review-diff fetches refs/pull/<n>/head when pr_head= is absent"
}

test_no_pr_meta_uses_local_branch() {
  local case_dir out
  case_dir=$(make_case no-pr-meta)
  stale_and_pr_commits "$case_dir"
  write_task_meta "$case_dir"

  out=$(run_review_diff "$case_dir" task-x1 2> "$case_dir/stderr")

  assert_contains "$out" '+stale-local' "no-pr-meta: diff should still use the local branch"
  assert_not_contains "$out" '+pr-fixed' "no-pr-meta: diff must not jump to the unpushed PR commit"
  assert_not_contains "$(cat "$case_dir/stderr")" 'warning: PR head unavailable' \
    "no-pr-meta: no warning without pr= in meta"
  pass "fm-review-diff without pr= keeps the worktree-branch diff"
}

test_unreachable_pr_head_falls_back_with_warning() {
  local case_dir out err
  case_dir=$(make_case fetch-fallback)
  stale_and_pr_commits "$case_dir"
  git -C "$case_dir/wt" remote remove origin
  write_task_meta "$case_dir" \
    "pr=https://github.com/example/repo/pull/9" \
    "pr_head=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"

  set +e
  out=$(run_review_diff "$case_dir" task-x1 2> "$case_dir/stderr")
  set -e
  err=$(cat "$case_dir/stderr")

  assert_contains "$err" 'warning: PR head unavailable; diff may lag the open PR' \
    "fetch-fallback: must warn when PR head cannot be resolved"
  assert_contains "$out" '+stale-local' "fetch-fallback: should fall back to the local branch diff"
  assert_not_contains "$out" '+pr-fixed' "fetch-fallback: must not invent a PR head diff offline"
  assert_contains "$out" 'COULD NOT OBSERVE PR HEAD' \
    "fetch-fallback: stdout must carry an explicit could-not-observe label"
  assert_contains "$out" 'compares the LOCAL branch fm/task-x1 as a fallback' \
    "fetch-fallback: label must say the shown diff is the local-branch fallback"
  assert_not_contains "$out" 'COULD NOT OBSERVE LIVE PR HEAD' \
    "fetch-fallback: local fallback label must be distinct from the recorded-head label"
  assert_contains "$out" 'diff compare: local branch fm/task-x1 ' \
    "fetch-fallback: header must name the local branch as the compare side"
  pass "fm-review-diff falls back to local branch with a warning when PR head is unreachable"
}


# run_review_diff_rc <case_dir> <args...>: run and capture rc without tripping set -e.
run_review_diff_rc() {
  local case_dir=$1
  shift
  set +e
  run_review_diff "$case_dir" "$@" > "$case_dir/stdout" 2> "$case_dir/stderr"
  RC=$?
  set -e
}

assert_refuses() {
  local case_dir=$1 needle=$2 label=$3
  [ "$RC" -ne 0 ] || fail "$label: expected nonzero exit, got 0"$'\n'"--- stdout ---"$'\n'"$(cat "$case_dir/stdout")"
  assert_contains "$(cat "$case_dir/stderr")" "$needle" "$label: refusal must name the bad input"
  [ ! -s "$case_dir/stdout" ] || fail "$label: a refusal must not print a diff"$'\n'"--- stdout ---"$'\n'"$(cat "$case_dir/stdout")"
}

test_header_pins_exact_shas() {
  local case_dir out base_sha compare_sha
  case_dir=$(make_case header-shas)
  stale_and_pr_commits "$case_dir"
  write_task_meta "$case_dir"

  out=$(run_review_diff "$case_dir" task-x1 --stat 2> "$case_dir/stderr")
  base_sha=$(git -C "$case_dir/wt" rev-parse origin/main)
  compare_sha=$(git -C "$case_dir/wt" rev-parse fm/task-x1)

  assert_contains "$out" "diff base: origin/main $base_sha" \
    "header-shas: header must print the symbolic base and its exact SHA"
  assert_contains "$out" "diff compare: local branch fm/task-x1 $compare_sha" \
    "header-shas: header must print the compare source and its exact SHA"
  assert_contains "$out" "merge-base: $base_sha" \
    "header-shas: header must print the merge-base the diff starts from"
  [ "$base_sha" != "$compare_sha" ] || fail "header-shas: fixture did not diverge base vs compare"
  pass "fm-review-diff header pins base and compare to exact commit SHAs"
}

test_no_changes_reports_pinned_base() {
  local case_dir out base_sha
  case_dir=$(make_case no-changes)
  write_task_meta "$case_dir"

  out=$(run_review_diff "$case_dir" task-x1 2> "$case_dir/stderr")
  base_sha=$(git -C "$case_dir/wt" rev-parse origin/main)

  assert_contains "$out" "no changes vs origin/main $base_sha" \
    "no-changes: the empty result must still name the pinned base SHA"
  pass "fm-review-diff reports an empty diff against the pinned base SHA"
}

test_rename_shows_old_and_new_paths() {
  local case_dir out stat_out
  case_dir=$(make_case rename)
  mkdir -p "$case_dir/wt/moved"
  git -C "$case_dir/wt" mv feature.txt moved/feature-renamed.txt
  git -C "$case_dir/wt" commit -qm "rename feature"
  write_task_meta "$case_dir"

  stat_out=$(run_review_diff "$case_dir" task-x1 --stat 2> "$case_dir/stderr")
  out=$(run_review_diff "$case_dir" task-x1 2> "$case_dir/stderr")

  assert_contains "$stat_out" 'feature.txt => moved/feature-renamed.txt' \
    "rename: --stat must show old => new path"
  assert_contains "$stat_out" 'renamed 1' "rename: summary must count the rename"
  assert_contains "$stat_out" 'deleted 0' "rename: a rename must not be counted as a deletion"
  assert_contains "$out" 'rename from feature.txt' "rename: full diff must name the old side"
  assert_contains "$out" 'rename to moved/feature-renamed.txt' "rename: full diff must name the new side"
  assert_not_contains "$out" 'deleted file mode' \
    "rename: full diff must not present the rename as a delete+add pair"
  pass "fm-review-diff shows old and new paths for a renamed file under --stat and full diff"
}

test_deletion_is_listed_and_counted() {
  local case_dir out
  case_dir=$(make_case deletion)
  git -C "$case_dir/wt" rm -q second.txt
  printf 'edited\n' > "$case_dir/wt/feature.txt"
  printf 'new\n' > "$case_dir/wt/added.txt"
  git -C "$case_dir/wt" add feature.txt added.txt
  git -C "$case_dir/wt" commit -qm "delete second, edit feature, add added"
  write_task_meta "$case_dir"

  out=$(run_review_diff "$case_dir" task-x1 --stat 2> "$case_dir/stderr")

  assert_contains "$out" 'changed paths: 3 (added 1, modified 1, deleted 1' \
    "deletion: summary must count the deleted path alongside the others"
  assert_contains "$out" "D$(printf '\t')second.txt" \
    "deletion: the deleted path must be listed in the changed-path view"
  assert_contains "$out" 'second.txt' "deletion: --stat must include the deleted file"
  out=$(run_review_diff "$case_dir" task-x1 2> "$case_dir/stderr")
  assert_contains "$out" 'deleted file mode' "deletion: full diff must show the deletion"
  pass "fm-review-diff lists and counts a deleted file"
}

test_malformed_pr_refuses() {
  local case_dir
  case_dir=$(make_case malformed-pr)
  stale_and_pr_commits "$case_dir"
  git -C "$case_dir/wt" push -q origin "pr-head-tmp:refs/pull/9/head"

  # Previously tolerated: trailing garbage after the PR number parsed to 9 and
  # silently reviewed that PR. Now it refuses, even though PR 9 is reachable.
  write_task_meta "$case_dir" "pr=https://github.com/example/repo/pull/9abc"
  run_review_diff_rc "$case_dir" task-x1
  assert_refuses "$case_dir" "malformed pr= 'https://github.com/example/repo/pull/9abc'" \
    "malformed-pr: trailing garbage after the PR number"

  # Previously tolerated: an unparseable pr= fell through to the local branch.
  write_task_meta "$case_dir" "pr=not-a-pull-request"
  run_review_diff_rc "$case_dir" task-x1
  assert_refuses "$case_dir" "malformed pr= 'not-a-pull-request'" "malformed-pr: non-URL non-number"

  # Previously tolerated: an empty pr= behaved as absent.
  write_task_meta "$case_dir" "pr="
  run_review_diff_rc "$case_dir" task-x1
  assert_refuses "$case_dir" "malformed pr= ''" "malformed-pr: empty value"

  # A bare positive PR number is still accepted and still fetches the pull head.
  write_task_meta "$case_dir" "pr=9"
  run_review_diff_rc "$case_dir" task-x1
  [ "$RC" -eq 0 ] || fail "malformed-pr: a bare PR number must still be accepted"$'\n'"$(cat "$case_dir/stderr")"
  assert_contains "$(cat "$case_dir/stdout")" '+pr-fixed' "malformed-pr: bare number must review the fetched PR head"
  pass "fm-review-diff refuses a malformed pr= naming the field"
}

test_malformed_pr_head_refuses() {
  local case_dir
  case_dir=$(make_case malformed-pr-head)
  stale_and_pr_commits "$case_dir"
  git -C "$case_dir/wt" push -q origin "pr-head-tmp:refs/pull/9/head"

  # Previously tolerated: a non-SHA pr_head= was ignored once the fetch succeeded.
  write_task_meta "$case_dir" "pr=https://github.com/example/repo/pull/9" "pr_head=not-a-sha"
  run_review_diff_rc "$case_dir" task-x1
  assert_refuses "$case_dir" "malformed pr_head= 'not-a-sha'" "malformed-pr-head: non-hex value"

  write_task_meta "$case_dir" "pr=https://github.com/example/repo/pull/9" "pr_head=abc123"
  run_review_diff_rc "$case_dir" task-x1
  assert_refuses "$case_dir" "malformed pr_head= 'abc123'" "malformed-pr-head: short hex value"
  pass "fm-review-diff refuses a malformed pr_head= naming the field"
}

test_duplicate_fields_refuse() {
  local case_dir
  case_dir=$(make_case duplicate-fields)
  stale_and_pr_commits "$case_dir"
  git -C "$case_dir/wt" push -q origin "pr-head-tmp:refs/pull/9/head"

  # Previously tolerated: the last pr= line silently won.
  write_task_meta "$case_dir" \
    "pr=https://github.com/example/repo/pull/8" \
    "pr=https://github.com/example/repo/pull/9"
  run_review_diff_rc "$case_dir" task-x1
  assert_refuses "$case_dir" '2 pr= lines' "duplicate-fields: conflicting pr= lines"

  write_task_meta "$case_dir" \
    "pr=https://github.com/example/repo/pull/9" \
    "pr_head=$PR_SHA" \
    "pr_head=$PR_SHA"
  run_review_diff_rc "$case_dir" task-x1
  assert_refuses "$case_dir" '2 pr_head= lines' "duplicate-fields: repeated pr_head= lines"

  fm_write_meta "$case_dir/state/task-x1.meta" \
    "worktree=$case_dir/wt" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project"
  run_review_diff_rc "$case_dir" task-x1
  assert_refuses "$case_dir" '2 worktree= lines' "duplicate-fields: repeated worktree= lines"

  fm_write_meta "$case_dir/state/task-x1.meta" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "project=$case_dir/elsewhere"
  run_review_diff_rc "$case_dir" task-x1
  assert_refuses "$case_dir" '2 project= lines' "duplicate-fields: conflicting project= lines"
  pass "fm-review-diff refuses duplicate worktree=, project=, pr=, and pr_head= fields"
}

test_malformed_arguments_refuse() {
  local case_dir
  case_dir=$(make_case malformed-args)
  stale_and_pr_commits "$case_dir"
  write_task_meta "$case_dir"

  # Previously tolerated: a flag in the id slot was looked up as a task named --stat.
  run_review_diff_rc "$case_dir" --stat task-x1
  assert_refuses "$case_dir" "unparseable argument '--stat'" "malformed-args: flag in the id slot"

  run_review_diff_rc "$case_dir" task-x1 --bogus
  assert_refuses "$case_dir" "unparseable argument '--bogus'" "malformed-args: unknown option"

  run_review_diff_rc "$case_dir" task-x1 --stat extra
  assert_refuses "$case_dir" "unparseable extra argument 'extra'" "malformed-args: extra argument"

  run_review_diff_rc "$case_dir" '../task-x1'
  assert_refuses "$case_dir" "unparseable argument '../task-x1'" "malformed-args: unsafe task id"

  run_review_diff_rc "$case_dir" task-x1 --stat
  [ "$RC" -eq 0 ] || fail "malformed-args: the documented --stat form must still succeed"$'\n'"$(cat "$case_dir/stderr")"
  assert_contains "$(cat "$case_dir/stdout")" 'feature.txt' "malformed-args: --stat must still print the stat"
  assert_not_contains "$(cat "$case_dir/stdout")" '+stale-local' "malformed-args: --stat must not print the full diff"
  pass "fm-review-diff refuses unparseable arguments naming the argument"
}

test_preexisting_refusals_still_refuse() {
  local case_dir
  case_dir=$(make_case preexisting)
  stale_and_pr_commits "$case_dir"

  run_review_diff_rc "$case_dir" task-none
  assert_refuses "$case_dir" 'no meta for task task-none' "preexisting: missing meta"

  fm_write_meta "$case_dir/state/task-x1.meta" "project=$case_dir/project"
  run_review_diff_rc "$case_dir" task-x1
  assert_refuses "$case_dir" 'missing worktree=' "preexisting: missing worktree= field"

  fm_write_meta "$case_dir/state/task-x1.meta" "worktree=$case_dir/wt"
  run_review_diff_rc "$case_dir" task-x1
  assert_refuses "$case_dir" 'missing project=' "preexisting: missing project= field"

  fm_write_meta "$case_dir/state/task-x1.meta" "worktree=$case_dir/gone" "project=$case_dir/project"
  run_review_diff_rc "$case_dir" task-x1
  assert_refuses "$case_dir" 'worktree for task task-x1 is missing' "preexisting: missing worktree directory"

  fm_write_meta "$case_dir/state/task-x1.meta" "worktree=$case_dir/wt" "project=$case_dir/gone"
  run_review_diff_rc "$case_dir" task-x1
  assert_refuses "$case_dir" 'project for task task-x1 is missing' "preexisting: missing project directory"

  # Detached worktree with no fm/<id> branch: the compare side cannot be named.
  fm_write_meta "$case_dir/state/task-x1.meta" "worktree=$case_dir/wt" "project=$case_dir/project"
  git -C "$case_dir/wt" checkout -q --detach
  git -C "$case_dir/wt" branch -q -D fm/task-x1
  run_review_diff_rc "$case_dir" task-x1
  assert_refuses "$case_dir" 'branch fm/task-x1 does not exist and worktree' "preexisting: detached worktree"

  run_review_diff_rc "$case_dir"
  [ "$RC" -ne 0 ] || fail "preexisting: no arguments must still refuse"
  assert_contains "$(cat "$case_dir/stderr")" 'usage: fm-review-diff.sh' "preexisting: no arguments prints usage"
  pass "fm-review-diff keeps every pre-existing refusal"
}

test_pr_meta_uses_pr_head_not_stale_local
test_pr_meta_fetches_pull_head_without_recorded_sha
test_stale_recorded_pr_head_loses_to_fetched_pull_head
test_no_pr_meta_uses_local_branch
test_unreachable_pr_head_falls_back_with_warning
test_header_pins_exact_shas
test_no_changes_reports_pinned_base
test_rename_shows_old_and_new_paths
test_deletion_is_listed_and_counted
test_malformed_pr_refuses
test_malformed_pr_head_refuses
test_duplicate_fields_refuse
test_malformed_arguments_refuse
test_preexisting_refusals_still_refuse
