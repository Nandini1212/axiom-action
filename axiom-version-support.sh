#!/usr/bin/env bash
#
# axiom-version-support.sh -- sourced (not executed), defines version_supports_workspace.
#
# axiom-version is normally one of this project's own vMAJOR.MINOR.PATCH release tags (see
# docs/24-github-action-design.md's Fifth/Sixth corrections) -- --workspace ships starting
# v1.2.0, and older installed CLI binaries reject it outright ("Unknown flag: --workspace",
# exit 2), so action.yml must only pass --workspace to a CLI new enough to understand it.
#
# But axiom-version is still a user-supplied Action input, not a value this script controls --
# a caller can pass `latest`, a SHA, or a typo. version_supports_workspace must never let a
# malformed value fail the Action; an input it doesn't recognize as a supported-or-not version
# is treated the same as "not supported yet" (false), never a shell arithmetic error.
#
# Emits its result on stdout ("true" or "false"), not a global variable -- action.yml consumes
# it as `[ "$(version_supports_workspace "$AXIOM_VERSION")" = "true" ] && ...`, the same
# capture-and-compare shape used elsewhere in this file's callers.
#
# Deliberately does not `set -euo pipefail`: this file is sourced into an already-running script
# (action.yml's own run block, or test-axiom-version-support.sh), matching report-args.sh's own
# reasoning for the same choice.
version_supports_workspace() {
  local version_no_v="${1#v}"

  # Fail closed on anything that isn't exactly MAJOR.MINOR.PATCH, all-numeric. Bash-specific
  # ([[ =~ ]]), which is fine here: action.yml declares `shell: bash` explicitly for every step
  # that sources this file.
  if ! [[ "$version_no_v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo false
    return
  fi

  local major="${version_no_v%%.*}"
  local rest="${version_no_v#*.}"
  local minor="${rest%%.*}"

  if [ "$major" -gt 1 ] || { [ "$major" -eq 1 ] && [ "$minor" -ge 2 ]; }; then
    echo true
  else
    echo false
  fi
}

# Populates the global array ARGS_WORKSPACE with `--workspace <path>` if and only if $1 (the
# axiom-version) supports it and $2 (the workspace path) is non-empty; empty otherwise. This is
# the exact argument-construction decision action.yml's own run script needs to make -- extracted
# here instead of leaving `[ "$(version_supports_workspace ...)" = "true" ] && [ -n ... ] &&
# ARGS+=(...)` as inline boolean logic nobody tests directly, matching build_report_args
# (report-args.sh)'s own precedent: the same function under test is the same function that ships,
# and a boundary this easy to get backwards (see the "= false" typo this test file specifically
# guards against) deserves a direct assertion, not just correctness-by-inspection.
build_workspace_args() {
  local version="$1"
  local workspace="$2"
  ARGS_WORKSPACE=()
  if [ "$(version_supports_workspace "$version")" = "true" ] && [ -n "$workspace" ]; then
    ARGS_WORKSPACE+=(--workspace "$workspace")
  fi
}

# --resolution-history ships starting v1.1.0 (confirmed directly against real tagged releases --
# absent from v1.0.0's InvestigateCommand, present from v1.1.0 onward through the current v1.5.1
# default) -- an older installed CLI (only v1.0.0 today) rejects it outright ("Unknown flag:
# --resolution-history", exit 2), so action.yml must only pass it to a CLI new enough to understand
# it, the same reasoning version_supports_workspace already established for --workspace. This gate
# exists purely so a caller who pins an old axiom-version (however unlikely in practice) while also
# supplying resolution-history-path fails soft (flag silently withheld) rather than with a
# confusing unknown-flag crash -- --resolution-history itself is a real, already-released CLI
# capability; only this Action's own exposure of it is new.
version_supports_resolution_history() {
  local version_no_v="${1#v}"

  if ! [[ "$version_no_v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo false
    return
  fi

  local major="${version_no_v%%.*}"
  local rest="${version_no_v#*.}"
  local minor="${rest%%.*}"

  if [ "$major" -gt 1 ] || { [ "$major" -eq 1 ] && [ "$minor" -ge 1 ]; }; then
    echo true
  else
    echo false
  fi
}

# Populates ARGS_RESOLUTION_HISTORY with `--resolution-history <path>` if and only if $1
# (axiom-version) supports it and $2 (the resolution-history-path input) is non-empty; empty
# otherwise -- the same "$2-or-nothing" gating shape build_workspace_args itself already
# establishes. Blank/omitted input means zero behavior change (no flag emitted), matching
# InvestigateCommand's own --resolution-history/--similar-failures mutual-exclusion contract: this
# Action never emits --similar-failures, so no conflict is possible from this side.
build_resolution_history_args() {
  local version="$1"
  local resolution_history_path="$2"
  ARGS_RESOLUTION_HISTORY=()
  if [ "$(version_supports_resolution_history "$version")" = "true" ] && [ -n "$resolution_history_path" ]; then
    ARGS_RESOLUTION_HISTORY+=(--resolution-history "$resolution_history_path")
  fi
}

# --run-id/--run-attempt/--job/--job-index ship starting v1.4.0 -- NOT yet an existing release tag
# as of this function's introduction (the latest at the time is v1.3.2); this threshold is this
# project's own best-effort next-version guess, following the same "new capability -> minor bump"
# convention v1.2.0 already set for --workspace, and MUST be corrected here (and in this file's own
# tests) if the actual tag cut for this feature turns out to differ. Getting the guess too low only
# risks a released CLI supporting these flags before an axiom-version bump makes the Action use
# them (silently degrades, same as any other not-yet-bumped axiom-version) -- never the
# unconditional unknown-flag crash this file's own --workspace history already proved unconditional
# passing causes against an older CLI (see test-axiom-version-support.sh's own comment on that).
version_supports_execution_identity() {
  local version_no_v="${1#v}"

  if ! [[ "$version_no_v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo false
    return
  fi

  local major="${version_no_v%%.*}"
  local rest="${version_no_v#*.}"
  local minor="${rest%%.*}"

  if [ "$major" -gt 1 ] || { [ "$major" -eq 1 ] && [ "$minor" -ge 4 ]; }; then
    echo true
  else
    echo false
  fi
}

# Populates ARGS_EXECUTION_IDENTITY with --run-id/--run-attempt/--job (only when the installed CLI
# supports them, and only when a value was actually supplied for each) plus --job-index
# (additionally gated on jobIndex being non-empty, since strategy.job-index is absent outside a
# matrix job -- absence must never become a manufactured sentinel).
build_execution_identity_args() {
  local version="$1"
  local run_id="$2"
  local run_attempt="$3"
  local job="$4"
  local job_index="$5"
  ARGS_EXECUTION_IDENTITY=()
  if [ "$(version_supports_execution_identity "$version")" = "true" ]; then
    # Each check is an `if` condition, never a bare `[ ... ] && ARGS+=(...)` statement: under
    # `set -e` (as in test-axiom-version-support.sh), a bare `&&` list whose first command is
    # false aborts the whole script, since `set -e` only exempts a failing command that is the
    # condition of an if/while/until, not one used as a standalone statement.
    if [ -n "$run_id" ]; then
      ARGS_EXECUTION_IDENTITY+=(--run-id "$run_id")
    fi
    if [ -n "$run_attempt" ]; then
      ARGS_EXECUTION_IDENTITY+=(--run-attempt "$run_attempt")
    fi
    if [ -n "$job" ]; then
      ARGS_EXECUTION_IDENTITY+=(--job "$job")
    fi
    if [ -n "$job_index" ]; then
      ARGS_EXECUTION_IDENTITY+=(--job-index "$job_index")
    fi
  fi
}

# --execution-occurrence-id ships in the same unreleased version as the other execution-identity
# flags (v1.4.0, see version_supports_execution_identity's own comment for why that threshold is a
# best-effort guess needing confirmation at the real tag), so it reuses that same capability check
# rather than inventing a second, independently-guessed threshold for a capability that ships
# alongside the first. Unlike run-id/run-attempt/job/job-index, this value is never auto-derived --
# it is only ever emitted when the caller explicitly supplied a non-blank Action input, which is
# why it has its own function instead of joining build_execution_identity_args (a different kind
# of argument-construction decision: "did the version-gate pass AND did the caller opt in", not
# "did the version-gate pass" alone).
build_execution_occurrence_args() {
  local version="$1"
  local execution_occurrence_id="$2"
  ARGS_EXECUTION_OCCURRENCE=()
  if [ "$(version_supports_execution_identity "$version")" = "true" ] && [ -n "$execution_occurrence_id" ]; then
    ARGS_EXECUTION_OCCURRENCE+=(--execution-occurrence-id "$execution_occurrence_id")
  fi
}

# --action-namespace reuses version_supports_execution_identity's own v1.4.0 threshold rather than
# inventing a second, independently-guessed placeholder. That threshold is already this project's
# best-effort guess for "the next tag cut from today's unreleased main" (see that function's own
# comment) -- --action-namespace lands on this same unreleased main before any v1.4.0 tag is cut,
# so it ships in the same release execution-occurrence-id does, exactly like execution-occurrence-id
# itself reused the identical threshold instead of guessing its own. No new version number is
# fabricated here. Same "caller must opt in explicitly, never auto-derived" shape as
# build_execution_occurrence_args immediately above -- --action-namespace is emitted only when the
# version gate passes AND the caller actually supplied a non-blank Action input.
build_action_namespace_args() {
  local version="$1"
  local action_namespace="$2"
  ARGS_ACTION_NAMESPACE=()
  if [ "$(version_supports_execution_identity "$version")" = "true" ] && [ -n "$action_namespace" ]; then
    ARGS_ACTION_NAMESPACE+=(--action-namespace "$action_namespace")
  fi
}

# --report-root (Product MVP M1 Slice 2, report auto-discovery) reuses
# version_supports_execution_identity's own v1.4.0 threshold for the identical reason
# build_execution_occurrence_args/build_action_namespace_args already do above: --report-root
# lands on this same unreleased main before any v1.4.0 tag is cut, so it ships in the same
# release the execution-identity flags do -- no new, independently-guessed version number is
# fabricated here.
#
# Unlike those two (which are pure "did the caller opt in" checks), this decision also depends on
# report-file: explicit --report always takes absolute precedence over discovery (see
# InvestigateCommand's own resolveEffectiveReports), so a non-blank report_file must suppress
# --report-root even when a workspace is available and the version supports it -- report auto-
# discovery only ever activates when the caller supplied no report-file at all. A blank workspace
# produces no argument either way, matching build_workspace_args's own "no workspace path produces
# no argument" case exactly -- report-root never falls back to any other path (never the current
# working directory), it simply has nothing to offer when no workspace value exists.
build_report_root_args() {
  local version="$1"
  local report_file="$2"
  local workspace="$3"
  ARGS_REPORT_ROOT=()
  if [ -z "$report_file" ] && [ -n "$workspace" ] \
      && [ "$(version_supports_execution_identity "$version")" = "true" ]; then
    ARGS_REPORT_ROOT+=(--report-root "$workspace")
  fi
}

# --report-occurrence-id (Decision 3B S1) reuses version_supports_execution_identity's own
# v1.4.0 threshold for the identical reason build_execution_occurrence_args/
# build_action_namespace_args/build_report_root_args already do above -- it ships on this same
# unreleased-at-introduction-time capability line, no new, independently-guessed version number
# is fabricated here.
#
# Resolves the effective value report-args.sh's build_report_args should receive as its own
# report-occurrence-id argument, rather than building an ARGS_* array itself: unlike
# --execution-occurrence-id/--action-namespace (single scalar CLI flags this file already
# constructs directly), --report-occurrence-id's actual --report/--report-occurrence-id pairing
# and cardinality validation belong entirely to build_report_args (report-args.sh already owns
# that pairing contract for --report itself) -- duplicating that logic here would be a second,
# competing implementation of the same pairing rule. This function's only job is the version
# gate: an unsupported version must never let the raw value reach build_report_args at all,
# resolving to empty exactly as if the caller had never supplied one, so build_report_args
# degrades to its pre-existing report-only behavior and never risks sending an unknown
# --report-occurrence-id flag to an older installed CLI.
#
# Populates the global EFFECTIVE_REPORT_OCCURRENCE_ID directly, the same "assign a global"
# convention build_workspace_args/build_execution_identity_args already use -- deliberately NOT
# version_supports_workspace's own "emit on stdout, caller captures via $(...)" convention,
# because $(...) unconditionally strips ALL trailing newlines from captured output, which would
# silently corrupt a multi-line report-occurrence-id value whose own trailing blank line is
# significant (it means "no id for the last report" -- see build_report_args's own handling of
# that exact case). A plain variable assignment preserves the value's newlines exactly.
build_report_occurrence_id_value() {
  local version="$1"
  local report_occurrence_id="$2"
  EFFECTIVE_REPORT_OCCURRENCE_ID=""
  if [ "$(version_supports_execution_identity "$version")" = "true" ]; then
    EFFECTIVE_REPORT_OCCURRENCE_ID="$report_occurrence_id"
  fi
}

# Decision 3B S2, docs/71-github-action-shadow-mode-design.md §6a. Computes the two scalar
# shadow-only derived identity defaults from GitHub-native context already available in the
# calling step -- never a new context read, never github.run_id/run_attempt/job/strategy.job-index
# used for anything but this already-established, already-documented purpose. The caller (action.yml)
# is responsible for only applying these when action-mode is exactly "shadow" and the corresponding
# input was left blank -- this function does not know about action-mode or blank-checking; it only
# computes the two values §6a defines, unconditionally, the same "pure computation, caller decides
# when to use it" shape build_workspace_args's own $2-or-nothing gating avoids duplicating elsewhere.
#
# execution-occurrence-id composite: run_id-run_attempt-job, with -job_index appended only when
# non-blank (a matrix job) -- job_index is never a manufactured sentinel for a non-matrix run,
# matching build_execution_identity_args's own identical treatment of the same value.
#
# action-namespace: exactly github.repository (passed in as $5), with the known rename-instability
# explicitly accepted only because shadow mode persists nothing keyed on it (§6a's own safety
# argument) -- this is NOT a general-purpose action-namespace default; it must never be reused for
# --execute-actions.
#
# Populates two globals, DERIVED_EXECUTION_OCCURRENCE_ID and DERIVED_ACTION_NAMESPACE -- plain
# variable assignment, not stdout+$(...) capture, matching build_report_occurrence_id_value's own
# reasoning (though neither of these two values is multi-line, consistency with the established
# convention in this file is preferred over reintroducing the stdout-capture shape for no reason).
build_shadow_identity_defaults() {
  local run_id="$1"
  local run_attempt="$2"
  local job="$3"
  local job_index="$4"
  local repo="$5"
  DERIVED_EXECUTION_OCCURRENCE_ID="${run_id}-${run_attempt}-${job}"
  if [ -n "$job_index" ]; then
    DERIVED_EXECUTION_OCCURRENCE_ID="${DERIVED_EXECUTION_OCCURRENCE_ID}-${job_index}"
  fi
  DERIVED_ACTION_NAMESPACE="$repo"
}

# Decision 3B S2, docs/71 §6/§14. Populates ARGS_ACTION_SHADOW with --action-shadow (and, only when
# $3/action-destination is non-blank, --action-destination <value> --authorize-create-issue-destination
# <value> -- the identical value fed to both flags, Option B's own collapsed-destination choice) when
# $2/action-mode is exactly "shadow" and $1/axiom-version supports the execution-identity capability
# line (the same v1.4.0 threshold --action-shadow/--action-destination/
# --authorize-create-issue-destination themselves shipped in -- confirmed directly via `git tag
# --contains` against the commit that introduced them, not guessed; no new version threshold is
# introduced here). Empty otherwise -- action-mode omitted/anything other than exactly "shadow", or
# an unsupported version, must both degrade to exactly today's pre-3B behavior: no shadow flags at
# all, never a partial/malformed invocation.
#
# Deliberately does NOT itself validate that action_destination is non-blank when action_mode is
# "shadow" -- emitting --action-shadow alone (no --action-destination) is intentional: the CLI's own
# existing, already-tested usage error ("--action-shadow/--execute-actions requires a nonblank
# --action-destination") fires in that case, the same "don't duplicate a validation the CLI already
# owns" discipline this codebase applies elsewhere (e.g. --report-occurrence-id's own immediate-
# pairing error is InvestigateCommand's, never reimplemented in report-args.sh).
#
# Never constructs, references, or has any awareness of --execute-actions or
# --action-destination-mapping -- those remain completely absent from this file and from action.yml,
# by construction, not by a runtime check.
build_action_shadow_args() {
  local version="$1"
  local action_mode="$2"
  local action_destination="$3"
  ARGS_ACTION_SHADOW=()
  if [ "$action_mode" = "shadow" ] && [ "$(version_supports_execution_identity "$version")" = "true" ]; then
    ARGS_ACTION_SHADOW+=(--action-shadow)
    if [ -n "$action_destination" ]; then
      ARGS_ACTION_SHADOW+=(--action-destination "$action_destination" \
        --authorize-create-issue-destination "$action_destination")
    fi
  fi
}

# --action-proposed-output (Decision 3B S4, docs/71-github-action-shadow-mode-design.md §14) is a
# genuinely new CLI capability that does not exist in any release through v1.5.1 -- unlike S1-S3's
# own flags, it cannot reuse version_supports_execution_identity's v1.4.0 threshold, since every
# already-released v1.4.0/v1.5.0/v1.5.1 binary predates it.
#
# ACTIVATED (v1.6.0 release): docs/76-v1.6-release-checklist.md was committed before tagging, the
# v1.6.0 tag was cut, and the released artifact was independently verified to actually expose
# --action-proposed-output before this threshold was activated -- following the exact
# docs/66/69/76-established sequence this function's own prior comment anticipated. Same
# major/minor comparison shape every other gate in this file already uses (see
# version_supports_execution_identity above).
version_supports_action_proposed_output() {
  local version_no_v="${1#v}"

  if ! [[ "$version_no_v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo false
    return
  fi

  local major="${version_no_v%%.*}"
  local rest="${version_no_v#*.}"
  local minor="${rest%%.*}"

  if [ "$major" -gt 1 ] || { [ "$major" -eq 1 ] && [ "$minor" -ge 6 ]; }; then
    echo true
  else
    echo false
  fi
}

# Populates ARGS_ACTION_PROPOSED_OUTPUT with --action-proposed-output <path> only when $1
# (axiom-version) supports it and $2 (the path this invocation should write to) is non-empty --
# empty otherwise, the same "$2-or-nothing" gating shape build_workspace_args itself already
# establishes. An unsupported version never receives this flag at all (silently withheld, never an
# unknown-flag failure), matching every other not-yet-released flag in this file exactly.
build_action_proposed_output_args() {
  local version="$1"
  local action_proposed_output_path="$2"
  ARGS_ACTION_PROPOSED_OUTPUT=()
  if [ "$(version_supports_action_proposed_output "$version")" = "true" ] && [ -n "$action_proposed_output_path" ]; then
    ARGS_ACTION_PROPOSED_OUTPUT+=(--action-proposed-output "$action_proposed_output_path")
  fi
}

# --historical-feedback ships starting v1.4.0 (confirmed directly via `git tag --contains` against
# the commit that introduced it -- cbede74, first present in v1.4.0, same release
# version_supports_execution_identity's own threshold already covers, though this is its own
# dedicated function rather than a reuse: unlike execution-occurrence-id/action-namespace/
# report-root, whose own comments explain why they ship in lockstep with the execution-identity
# capability line itself, historical feedback is a conceptually unrelated capability that merely
# happens to share a release -- naming it after the unrelated capability it would otherwise borrow
# from would read wrong at every future call site.
version_supports_historical_feedback() {
  local version_no_v="${1#v}"

  if ! [[ "$version_no_v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo false
    return
  fi

  local major="${version_no_v%%.*}"
  local rest="${version_no_v#*.}"
  local minor="${rest%%.*}"

  if [ "$major" -gt 1 ] || { [ "$major" -eq 1 ] && [ "$minor" -ge 4 ]; }; then
    echo true
  else
    echo false
  fi
}

# Populates ARGS_HISTORICAL_FEEDBACK with --historical-feedback (no value -- InvestigateCommand
# parses this as a bare presence flag) if and only if $1 (axiom-version) supports it and $2 (the
# historical-feedback Action input) is exactly "true"; empty otherwise. An unsupported version
# never receives this flag at all (silently withheld, never an unknown-flag failure), matching
# every other not-yet-released flag in this file.
build_historical_feedback_args() {
  local version="$1"
  local historical_feedback="$2"
  ARGS_HISTORICAL_FEEDBACK=()
  if [ "$(version_supports_historical_feedback "$version")" = "true" ] && [ "$historical_feedback" = "true" ]; then
    ARGS_HISTORICAL_FEEDBACK+=(--historical-feedback)
  fi
}

# --enable-history-influence ships starting v1.6.0 (confirmed directly via `git tag --contains`
# against the commit that introduced it -- 93812d9, absent from v1.5.1, first present in v1.6.0) --
# a full two minor releases after --historical-feedback itself (v1.4.0, see
# version_supports_historical_feedback above). This later threshold must never be conflated with
# that earlier one: a v1.4.0-v1.5.1 installed CLI already understands --historical-feedback but
# rejects --enable-history-influence outright ("Unknown flag", exit 2), so this capability needs
# its own, independently-verified version gate rather than reusing either
# version_supports_historical_feedback or version_supports_action_proposed_output (which happens to
# share the same v1.6.0 numeric threshold by coincidence of release timing, not by any real
# relationship to this capability).
version_supports_history_influence() {
  local version_no_v="${1#v}"

  if ! [[ "$version_no_v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo false
    return
  fi

  local major="${version_no_v%%.*}"
  local rest="${version_no_v#*.}"
  local minor="${rest%%.*}"

  if [ "$major" -gt 1 ] || { [ "$major" -eq 1 ] && [ "$minor" -ge 6 ]; }; then
    echo true
  else
    echo false
  fi
}

# Populates ARGS_HISTORY_INFLUENCE with --enable-history-influence (no value, same bare-presence
# shape as --historical-feedback above) if and only if $1 (axiom-version) supports it and $2 (the
# enable-history-influence Action input) is exactly "true"; empty otherwise. Deliberately does NOT
# validate that the historical-feedback input was also enabled, or that repository context is
# available -- action.yml always passes --repo/--commit unconditionally (so that half of
# InvestigateCommand's own "--enable-history-influence requires --repo" usage error can never
# actually trigger through this Action), and the remaining "--enable-history-influence requires
# --historical-feedback" case is left to the CLI's own existing, already-tested usage error, the
# same "don't duplicate a validation the CLI already owns" discipline build_action_shadow_args
# already applies to its own action-destination requirement.
build_history_influence_args() {
  local version="$1"
  local enable_history_influence="$2"
  ARGS_HISTORY_INFLUENCE=()
  if [ "$(version_supports_history_influence "$version")" = "true" ] && [ "$enable_history_influence" = "true" ]; then
    ARGS_HISTORY_INFLUENCE+=(--enable-history-influence)
  fi
}

# Decision 3C Slice 1 (AXIOM_DECISION_3C_EXPOSURE_BOUNDARY_DESIGN §5/§6/§7). Populates
# ARGS_EXECUTE_ACTIONS with the real-execution flags -- --execute-actions, this action's own
# explicit --authorize-create-issue-destination confirmation (never shadow's own collapsed value
# from build_action_shadow_args), and the one-entry --action-destination-mapping equivalent -- only
# when every one of these holds, checked in exactly this order (the first failing check sets
# EXECUTE_ACTIONS_DECLINED_REASON and returns immediately, never more than one reason):
#
#   1. $1/execute_actions is exactly "true" -- anything else (including a typo) is identical to
#      "false", the same bare-string-equality convention build_history_influence_args already uses.
#   2. $3/action_mode is exactly "shadow" -- action-mode: execute does not exist, by design (see
#      the approved exposure-boundary design); action-mode: off always means no real execution.
#   3. $2/version supports the execution-identity capability line --execute-actions itself ships
#      in -- an unsupported installed CLI must never see an unknown flag.
#   4. $5/authorize_create_issue_destination is non-blank AND exactly equals $4/action_destination
#      -- this action's own required, separate confirmation; never derived from action_destination,
#      the same "caller supplies it explicitly" contract build_action_shadow_args's own destination
#      parameter already establishes, applied here to authorization instead of display.
#   5. $6/action_destination_repository is non-blank -- the one owner/repo resolution this V1
#      exposes; no multi-entry mapping, no wildcard.
#
# Never emits action-mode=execute (it does not exist). Never emits more than one
# --action-destination-mapping entry. A caller who sets execute_actions=true without satisfying
# 2-5 gets no real-execution flags at all (a concise, deterministic notice via the caller-set
# EXECUTE_ACTIONS_DECLINED_REASON) -- never a partial attempt, never a silent fallback to shadow's
# own collapsed authorization.
# --ci-log-github-actions-job (Phase 3 M3.5), --ci-log-github-actions-run (M3.6), and
# --ci-log-github-actions-discover-run (M3.7) all ship together in the same release -- one shared
# version check for the whole family, following this file's own "one function per capability
# line, reused across every flag that ships in it" convention (see
# version_supports_execution_identity's own five callers above). v1.15.0 is this project's own
# best-effort next-version guess (the latest released tag as of this writing is v1.14.0, which
# predates all three flags -- confirmed directly via `git show v1.14.0:...` finding zero
# occurrences of any of them) -- MUST be corrected here (and in this file's own tests) if the
# actual tag cut for this work turns out to differ, the same "getting the guess too low only
# risks a released CLI supporting these flags before an axiom-version bump makes the Action use
# them -- never the unconditional unknown-flag crash this file exists to prevent" posture
# version_supports_execution_identity's own comment already established.
#
# Before this function existed, all three flags were appended to ARGS unconditionally (no version
# gate at all) -- confirmed, not assumed, that this let a caller on action.yml's own current
# default (v1.14.0) or any explicitly older pin hit a hard "Unknown flag" crash (exit 2) the
# moment any of these inputs was set, since the installed binary simply does not understand them.
version_supports_github_actions_ci_log() {
  local version_no_v="${1#v}"

  if ! [[ "$version_no_v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo false
    return
  fi

  local major="${version_no_v%%.*}"
  local rest="${version_no_v#*.}"
  local minor="${rest%%.*}"

  if [ "$major" -gt 1 ] || { [ "$major" -eq 1 ] && [ "$minor" -ge 15 ]; }; then
    echo true
  else
    echo false
  fi
}

# The one decline-reason message template shared by all three build_ci_log_github_actions_*_args
# functions below -- never a crash, never silence: a caller who explicitly requested one of these
# inputs against an unsupported axiom-version gets a clear, actionable explanation of exactly
# which input was withheld and why, the same "caller-visible reason, printed as a Note by
# action.yml" shape EXECUTE_ACTIONS_DECLINED_REASON already establishes. Unlike that single
# yes/no decision, this family has three independent inputs that could each independently be
# withheld, so this is a reusable text-building function, not a single global.
ci_log_github_actions_decline_reason() {
  local flag_name="$1"
  local version="$2"
  echo "--${flag_name} was requested but the installed axiom-version (${version}) does not support it -- requires v1.15.0 or newer; this input was withheld, diagnosis continues through whatever other evidence is available"
}

# Populates ARGS_CI_LOG_GITHUB_ACTIONS_JOB with --ci-log-github-actions-job <id> if and only if $1
# (axiom-version) supports it and $2 (the ci-log-github-actions-job input) is non-empty; empty
# otherwise -- the same "$2-or-nothing" gating shape build_workspace_args itself already
# establishes. Sets CI_LOG_GITHUB_ACTIONS_JOB_DECLINED_REASON (non-empty only when the caller
# explicitly supplied a value against an unsupported version) so action.yml can surface a clear
# Note instead of either silence or an unknown-flag crash.
build_ci_log_github_actions_job_args() {
  local version="$1"
  local job_id="$2"
  ARGS_CI_LOG_GITHUB_ACTIONS_JOB=()
  CI_LOG_GITHUB_ACTIONS_JOB_DECLINED_REASON=""
  if [ -z "$job_id" ]; then
    return
  fi
  if [ "$(version_supports_github_actions_ci_log "$version")" = "true" ]; then
    ARGS_CI_LOG_GITHUB_ACTIONS_JOB+=(--ci-log-github-actions-job "$job_id")
  else
    CI_LOG_GITHUB_ACTIONS_JOB_DECLINED_REASON="$(ci_log_github_actions_decline_reason "ci-log-github-actions-job" "$version")"
  fi
}

# Same shape as build_ci_log_github_actions_job_args immediately above, for
# --ci-log-github-actions-run.
build_ci_log_github_actions_run_args() {
  local version="$1"
  local run_id="$2"
  ARGS_CI_LOG_GITHUB_ACTIONS_RUN=()
  CI_LOG_GITHUB_ACTIONS_RUN_DECLINED_REASON=""
  if [ -z "$run_id" ]; then
    return
  fi
  if [ "$(version_supports_github_actions_ci_log "$version")" = "true" ]; then
    ARGS_CI_LOG_GITHUB_ACTIONS_RUN+=(--ci-log-github-actions-run "$run_id")
  else
    CI_LOG_GITHUB_ACTIONS_RUN_DECLINED_REASON="$(ci_log_github_actions_decline_reason "ci-log-github-actions-run" "$version")"
  fi
}

# Same gate, bare-presence-flag shape (matches build_historical_feedback_args exactly) for
# --ci-log-github-actions-discover-run.
build_ci_log_github_actions_discover_run_args() {
  local version="$1"
  local discover_run="$2"
  ARGS_CI_LOG_GITHUB_ACTIONS_DISCOVER_RUN=()
  CI_LOG_GITHUB_ACTIONS_DISCOVER_RUN_DECLINED_REASON=""
  if [ "$discover_run" != "true" ]; then
    return
  fi
  if [ "$(version_supports_github_actions_ci_log "$version")" = "true" ]; then
    ARGS_CI_LOG_GITHUB_ACTIONS_DISCOVER_RUN+=(--ci-log-github-actions-discover-run)
  else
    CI_LOG_GITHUB_ACTIONS_DISCOVER_RUN_DECLINED_REASON="$(ci_log_github_actions_decline_reason "ci-log-github-actions-discover-run" "$version")"
  fi
}

build_execute_actions_args() {
  local execute_actions="$1"
  local version="$2"
  local action_mode="$3"
  local action_destination="$4"
  local authorize_create_issue_destination="$5"
  local action_destination_repository="$6"
  ARGS_EXECUTE_ACTIONS=()
  EXECUTE_ACTIONS_DECLINED_REASON=""

  if [ "$execute_actions" != "true" ]; then
    return
  fi
  if [ "$action_mode" != "shadow" ]; then
    EXECUTE_ACTIONS_DECLINED_REASON="execute-actions was requested but action-mode is not 'shadow'"
    return
  fi
  if [ "$(version_supports_execution_identity "$version")" != "true" ]; then
    EXECUTE_ACTIONS_DECLINED_REASON="execute-actions was requested but the installed axiom-version does not support it"
    return
  fi
  if [ -z "$authorize_create_issue_destination" ] || [ "$authorize_create_issue_destination" != "$action_destination" ]; then
    EXECUTE_ACTIONS_DECLINED_REASON="execute-actions was requested but authorize-create-issue-destination is blank or does not exactly match action-destination"
    return
  fi
  if [ -z "$action_destination_repository" ]; then
    EXECUTE_ACTIONS_DECLINED_REASON="execute-actions was requested but action-destination-repository is blank"
    return
  fi

  ARGS_EXECUTE_ACTIONS+=(--execute-actions \
    --authorize-create-issue-destination "$authorize_create_issue_destination" \
    --action-destination-mapping "${action_destination}=${action_destination_repository}")
}

# `axiom pr-impact` itself has existed since v1.11.0 (confirmed via `git tag --contains` against
# b7eb5e3, the commit that introduced the subcommand -- present in every tag from v1.11.0 through
# the current default). But this gate's own threshold is deliberately later: v1.15.0, the first
# version whose RestGitHubApiClient.listCommitChangedFilesWithHunks paginates past GitHub's
# 300-changed-file page cap correctly (fixed by a commit not yet in any tagged release as of this
# writing -- confirmed via `git tag --contains` returning nothing for it) instead of failing
# outright with a generic "pagination is not supported" error. Every already-released version
# (v1.11.0 through the current default) shares that same defect for pr-impact's own
# single-commit scope, so there is no real, already-tagged version for which gating at v1.11.0
# would actually be safe -- this function intentionally does not reuse that earlier, lower
# threshold.
version_supports_pr_impact() {
  local version_no_v="${1#v}"

  if ! [[ "$version_no_v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo false
    return
  fi

  local major="${version_no_v%%.*}"
  local rest="${version_no_v#*.}"
  local minor="${rest%%.*}"

  if [ "$major" -gt 1 ] || { [ "$major" -eq 1 ] && [ "$minor" -ge 15 ]; }; then
    echo true
  else
    echo false
  fi
}

# Populates ARGS_PR_IMPACT with the exact `pr-impact` subcommand arguments to run, if and only if
# $1 (the pr-impact Action input) is exactly "true" and $2 (axiom-version) supports it per
# version_supports_pr_impact above; empty otherwise (never a partial/malformed command). $5 (the
# pull-request number) selects scope exactly the way the existing investigation above already
# does for --pr: full pull-request scope (every commit in the PR, base...head) when non-blank,
# single-commit scope (this commit's own diff only) otherwise -- never inferred any other way,
# and never both at once. PR_IMPACT_DECLINED_REASON mirrors
# EXECUTE_ACTIONS_DECLINED_REASON's own caller-visible-reason contract above, for the identical
# reason: a caller who asked for this must see why nothing ran, not silence.
build_pr_impact_args() {
  local pr_impact="$1"
  local version="$2"
  local repository="$3"
  local commit="$4"
  local pull_request="$5"
  ARGS_PR_IMPACT=()
  PR_IMPACT_DECLINED_REASON=""

  if [ "$pr_impact" != "true" ]; then
    return
  fi
  if [ "$(version_supports_pr_impact "$version")" != "true" ]; then
    PR_IMPACT_DECLINED_REASON="pr-impact was requested but the installed axiom-version ($version) does not support it -- v1.15.0 or newer is required"
    return
  fi

  ARGS_PR_IMPACT+=(pr-impact --repo "$repository" --commit "$commit")
  if [ -n "$pull_request" ]; then
    ARGS_PR_IMPACT+=(--pr "$pull_request")
  fi
}
