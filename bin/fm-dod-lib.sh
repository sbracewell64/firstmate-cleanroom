#!/usr/bin/env bash
# Single owner of a ship task's mode-specific "Definition of done" block.
# Sourced by bin/fm-brief.sh, which renders it into a generated ship brief, and by
# bin/fm-promote.sh, which renders it into the ship instructions a promoted scout
# receives. Both paths must hand the worker the same contract: a promoted
# no-mistakes worker that never received the ask-user escalation rule or the
# `--yes` ban is the exact delivery hole this single owner exists to close.
# fm_dod_block <no-mistakes|direct-PR|local-only> <task-id> prints the block on
# stdout with no trailing blank line. The caller validates the mode; an unknown
# mode is refused rather than silently rendered as the pipeline contract. The
# caller must have FM_ROOT (the tracked code root) and FM_HOME (this home)
# resolved: the block embeds them in the exact stage commands the worker runs,
# so a worker's shell never resolves the wrong home.
# The block opens with the fixed machine-readable "Delivery contract: mode=<mode>"
# line that bin/fm-spawn.sh checks a ship brief against.
# The ship lifecycle stages the block hands the worker (candidate-committed,
# validation-pending, validation-admitted, validation-running, ci-ready) are
# issued only by bin/fm-stage.sh, which owns the transition mechanics, the
# receipt fields, and the refusals; the worker never writes a stage line by
# hand, and bin/fm-classify-lib.sh owns how each stage verb classifies.
# Every heredoc here stays outside a command substitution: `VAR=$(cat <<EOF ...)`
# breaks parsing of the whole file on Bash 3.2 (tests/fm-brief.test.sh).

# The one quoted-command form every mode's block uses, so both scaffold paths
# render byte-identical stage commands for the same home and task.
fm_dod_stage_cmd() {  # <task-id>
  printf 'FM_HOME=%q %q %q' "$FM_HOME" "$FM_ROOT/bin/fm-stage.sh" "$1"
}

fm_dod_block() {  # <mode> <task-id>
  local mode=$1 id=$2 stage
  [ -n "${FM_ROOT:-}" ] && [ -n "${FM_HOME:-}" ] || {
    echo "error: fm_dod_block: the caller must resolve FM_ROOT and FM_HOME before rendering a definition of done" >&2
    return 1
  }
  stage=$(fm_dod_stage_cmd "$id")
  case "$mode" in
    direct-PR)
      cat <<EOF
# Definition of done
Delivery contract: mode=direct-PR
This task ships **direct-PR**: you raise the PR yourself, without the no-mistakes pipeline.
The task is complete only when committed on your branch.
When it is implemented and committed, record the candidate with \`$stage committed\` (it prints \`STAGE:\` and a \`next:\` line, and it is safe to repeat), then push your branch and open a PR with \`gh-axi\`, then append \`done: PR {url}\` to the status file and stop.
Do NOT run /no-mistakes. The configured merge authority decides whether to merge the PR; firstmate relays the outcome.
EOF
      ;;
    local-only)
      cat <<EOF
# Definition of done
Delivery contract: mode=local-only
This task ships **local-only**: no remote, no PR, no pipeline.
The task is complete only when committed on your branch \`fm/$id\`. Do NOT push, do NOT open a PR, do NOT merge.
Keep your branch a clean fast-forward onto the current default branch - if \`main\` has advanced, rebase onto it so the eventual merge stays a fast-forward.
When it is implemented and committed, record the candidate with \`$stage committed\` (it prints \`STAGE:\` and a \`next:\` line, and it is safe to repeat), then append \`done: ready in branch fm/$id\` to the status file and stop.
The configured merge authority approves the ready branch, then firstmate merges it into local \`main\` through the guarded fast-forward path.
EOF
      ;;
    no-mistakes)
      cat <<EOF
# Definition of done
Delivery contract: mode=no-mistakes
The task is complete only when committed on your branch and validated through the stage sequence below.
Every stage line in the status file is written by the stage command, never by hand, and never parsed from your own narration: run the command, read its \`STAGE:\`, \`STAGE_UNCHANGED:\`, or \`STAGE_REFUSED:\` line, and follow its \`next:\` line. Each command is safe to repeat.

1. After your implementation commit, run \`$stage committed\`.
   Because this task's delivery contract already admits validation, the command issues the validation transition itself: \`validation-admitted\` means start the pipeline now, on that committed head, without waiting for a message from firstmate; \`validation-pending\` means stop and wait (the line names the hold or the missing capacity), then re-run the same command when firstmate tells you the wait cleared.
   A \`STAGE_REFUSED:\` line names what it could not prove (an uncommitted or rewritten candidate, a missing worktree); fix that and re-run, and if the same refusal repeats, append \`blocked: {the typed line}\` and stop.
2. As soon as \`no-mistakes axi run\` has created the run, run \`$stage running\` (add \`--run <run-id>\` when you know it) so the real run is bound to your candidate.
3. After /no-mistakes reports CI green (the CI-ready return point - do not wait for it to keep monitoring in the background until merge), run \`$stage ci-ready --pr {url}\` and stop. You are finished; do not append \`done:\` for this task.
4. After a restart, run \`$stage show\` first and continue from the recorded stage.

You drive no-mistakes by responding to its gates, not by implementing fixes.
Follow the guidance no-mistakes itself provides for the mechanics: it loads when you invoke /no-mistakes, and \`no-mistakes axi run --help\` plus the \`help\` lines in each \`axi\` response are authoritative and version-matched to the installed binary.
When starting no-mistakes, make \`--intent\` preserve all relevant content from this brief's \`# Task\` section plus every later accepted Firstmate requirement, clarification, constraint, exclusion, and supersession, carrying only each requirement's current accepted form; retain direct requirements instead of substituting a diff summary, and exclude generic operational, status, delivery, and other scaffold boilerplate unless it is task-specific.
Do not hand-edit, commit, or fix findings yourself while a run is active - the pipeline applies every fix.

Two firstmate-specific rules layer on top of that guidance:
- ask-user findings are never yours to answer: escalate to firstmate (rule 6) and stop.
  Append \`needs-decision [key=<step>-<finding-id>]: awaiting firstmate decision - step=<step> finding=<finding-id> action=ask-user <one-line summary>\` so the finding identity, its owner, and where the answer applies are on the record; you are then awaiting firstmate's decision, and you never address the captain or name the captain as the one you stopped for.
  Firstmate applies \`ask-user-authority\` and obtains any required captain decision.
  When the decision comes back, feed it to the gate with \`no-mistakes axi respond\` and let the pipeline apply it - do not route the question to "the user" or implement the fix yourself.
- NEVER pass \`--yes\` (or \`-y\`) to \`no-mistakes axi run\` or \`no-mistakes axi respond\`. It is banned fleet-wide.
  It auto-resolves every gate including ask-user findings with no escalation, and answering your own ask-user finding is a hard rule violation.
EOF
      ;;
    *)
      echo "error: fm_dod_block: unknown delivery mode '$mode'" >&2
      return 1 ;;
  esac
}
