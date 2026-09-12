#!/usr/bin/env bash
# Single owner of the worker-discipline text a crewmate brief carries.
# Sourced by bin/fm-brief.sh, which renders it into a generated ship or scout
# brief, and by bin/fm-promote.sh, which renders the ship block into the ship
# instructions a promoted scout receives, so a promoted worker gets the same
# engineering contract as a briefed one (the same single-owner reason
# bin/fm-dod-lib.sh exists). Worker engineering discipline lives here; the
# delivery definition of done stays in bin/fm-dod-lib.sh, a different owner.
# fm_discipline_block ship [--shared-boundary] [--proof-surface <text>] prints
# the compact "# Worker discipline" section, followed by one narrowly scoped
# fragment per flag, on stdout with no trailing newline (callers add their own
# separator, so a brief and a promotion render byte-identical sections).
# fm_discipline_block scout prints the epistemic, read-only subset only
# ("# Evidence discipline"): a scout gains no code-writing inner loop.
# A secondmate charter renders nothing from here, and neither firstmate nor a
# secondmate ever loads this text as an operating mode.
# Every block grants no authority: it never lets a worker spawn or steer other
# workers, choose a model or provider route, change fleet state, reinterpret the
# delivery mode or acceptance, or merge. The Rules and Definition of done in the
# brief own those boundaries; this text only shapes how the worker engineers
# and proves the change inside them.
# The one machine-readable outcome token is `could-not-observe (CNO)`: an
# unobservable fact is recorded as CNO, never as a pass and never as safe.
# There is deliberately no second token for "not proven".
# A worker's `note: verification-gap: {one line}` status event names recurring
# manual verification, a flaky proof, or missing observability; firstmate files
# it as its own bounded work item (AGENTS.md section 10) instead of widening the
# finished task, and the worker never holds the task on it.
# Provenance: re-expressed in Firstmate language from two MIT-licensed sources,
# neither copied nor vendored. pstack 0.14.7 (https://github.com/cursor/plugins,
# subtree pstack/, MIT, Lauren Tan) at commit
# efa2a531985e0a8084d36ff3cf87233be8a9f34b: principle-prove-it-works,
# principle-subtract-before-you-add, principle-sequence-verifiable-units,
# principle-build-the-lever, the factual core of blast-radius, and the
# complexity gate of how. Ponytail (https://github.com/DietrichGebert/ponytail,
# MIT, Dietrich Gebert) at commit 2ed6c52c9d7e5e56942508591085fd45dea277d3
# (three commits after the v4.9.0 tag at 0a4dd63): the understand-first rule,
# the minimality ladder, root-cause-over-symptom, and the never-simplify-away
# list. No pstack or Ponytail runtime, hook, plugin, router, intensity level,
# model rule, or fan-out mechanism is adopted.
# Every heredoc here stays outside a command substitution: `VAR=$(cat <<EOF ...)`
# breaks parsing of the whole file on Bash 3.2 (tests/fm-brief.test.sh).

fm_discipline_block() {  # <ship|scout> [--shared-boundary] [--proof-surface <text>]
  local kind=$1 shared=0 surface='' want='' a block
  shift
  for a in "$@"; do
    if [ -n "$want" ]; then
      surface=$a
      want=''
      continue
    fi
    case "$a" in
      --shared-boundary) shared=1 ;;
      --proof-surface) want=proof-surface ;;
      --proof-surface=*) surface=${a#--proof-surface=} ;;
      *) echo "error: fm_discipline_block: unknown argument '$a'" >&2; return 1 ;;
    esac
  done
  [ -z "$want" ] || { echo "error: fm_discipline_block: --$want requires a value" >&2; return 1; }
  case "$kind" in
    scout)
      [ "$shared" -eq 0 ] && [ -z "$surface" ] || {
        echo "error: fm_discipline_block: --shared-boundary and --proof-surface apply only to ship work" >&2
        return 1
      }
      IFS= read -r -d '' block <<'EOF' || true
# Evidence discipline
Read the task and the code it touches before concluding; observe primary evidence - source, runtime behavior, real output - and cite it by file:line or by the command you ran.
Prove a claim by running the real thing where that is cheap; otherwise label the claim as inferred.
Keep evidence, inference, and what you could not verify as separate labeled findings; a result you could not observe is reported as could-not-observe (CNO), never rounded to a pass.
This grants no authority: your deliverable stays the report, which recommends and never instructs a merge or landing - a scratch edit never becomes a shipped change - and you still never push, open a PR, spawn or steer other workers, choose a model route, or change fleet state.
EOF
      printf '%s' "${block%$'\n'}"
      return 0
      ;;
    ship) ;;
    *) echo "error: fm_discipline_block: unknown kind '$kind'" >&2; return 1 ;;
  esac
  IFS= read -r -d '' block <<'EOF' || true
# Worker discipline
This section shapes how you engineer and prove the change; it grants no authority beyond the Rules above.
1. Understand first: read the task and the code it touches, and trace the real flow end to end when the change crosses or depends on a shared boundary or the task is diagnostic; otherwise say in one line why you skipped that walk. A small diff in the wrong owner is a second bug, not minimality.
2. Then climb the ladder: explicit acceptance first, subtract unnecessary work, reuse the existing owner or pattern, then standard or installed capabilities, then the smallest correct change. Stop at the first sufficient solution; preserve required edge cases and never widen scope with speculative abstractions or dependencies.
3. A bug fix repairs the root cause: inspect the materially analogous callers and entry paths of what you touch, and prefer one repair in the shared owner over a patch per symptom when the evidence supports that owner.
4. Exercise the changed command, caller, protocol or runtime and record its artifact identity, independent expected result and observed behavior. At shared APIs, schemas, persisted state or authority boundaries, prove the affected safety facts. Mark anything unobserved as could-not-observe (CNO), never pass or safe.
5. When important proof would otherwise need a repeated manual or reasoning-heavy procedure, write the smallest deterministic rerunnable check, run it, and keep it with the change; trivial work manufactures no tooling, and a framework is never the answer.
6. Minimality never outranks explicit acceptance criteria, the project's required tests and validators, the selected delivery path's own gates, security and privacy, validation at trust boundaries, error handling that prevents data loss, accessibility, or exact-head, provenance, and authority constraints.
7. Stay inside this assignment: only this worktree and scope; never spawn or steer other workers, choose a model or provider route, change fleet state, reinterpret the delivery mode or acceptance, or merge anything the contract below does not grant.
8. Return evidence, not authority: put the proof you ran and every CNO item in your commit message or PR description as candidate evidence for review; it never satisfies the delivery path's own gates or firstmate's acceptance by itself.
If recurring manual verification, a flaky proof, or missing observability kept a proof from being cheap, append one `note: verification-gap: {one line}` to the status file before the final lifecycle transition so firstmate can file a bounded follow-up; a required acceptance gap still follows the existing blocker or decision contract.
EOF
  printf '%s' "${block%$'\n'}"
  if [ "$shared" -eq 1 ]; then
    IFS= read -r -d '' block <<'EOF' || true

# Shared boundary
Firstmate marked this change as crossing a shared seam, so point 1's trace and point 4's safety facts are mandatory here, not conditional.
Trace the path through that seam - every caller, reader, and persisted form that meets it - and keep the walk to that seam, not a survey of the project; prove each safety fact with a script or test that fails loudly if the fact is false, and record CNO for any you could not run.
EOF
    printf '%s' "${block%$'\n'}"
  fi
  if [ -n "$surface" ]; then
    IFS= read -r -d '' block <<EOF || true

# Proof surface
Completion requires exercising this real surface: $surface
Passing tests alone do not satisfy it: drive the surface, record the observed result with your evidence, and if it cannot be reached record CNO rather than a pass.
EOF
    printf '%s' "${block%$'\n'}"
  fi
  return 0
}
