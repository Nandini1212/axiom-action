#!/usr/bin/env bash
#
# report-args.sh -- sourced (not executed), defines build_report_args.
#
# Translates action.yml's report-file input (one or more newline-separated JUnit report paths)
# into repeated `--report` flags for a single `axiom investigate` invocation -- matching the CLI's
# own MultiReportEvidenceReader semantics (several reports merge into one investigation, not
# several independent ones; see MultiReportEvidenceReader.java's own javadoc). Extracted into its
# own file, not written inline in action.yml, so it can be sourced identically by action.yml and
# by test-report-args.sh -- the same logic under test is the same logic that ships, never a
# reimplementation that could drift out of sync.
#
# A single-line report-file value (today's exact existing usage) produces exactly one --report
# flag, unchanged from before this file existed.
#
# Deliberately does not `set -euo pipefail`: this file is sourced into an already-running script
# (action.yml's own run block, or test-report-args.sh), and a sourced file changing the caller's
# shell options as a side effect would be a surprising, hard-to-trace behavior change -- action.yml
# already toggles `set +e`/`set -e` around its own axiom invocation deliberately, and this file has
# no business overriding that. The loop below doesn't need strict mode to behave correctly.

# Populates the global array ARGS_REPORT with alternating --report/<path> pairs, one pair per
# non-blank line of $1, optionally interleaved with --report-occurrence-id immediately after the
# --report it applies to -- matching axiom investigate's own immediate-pairing contract for that
# flag exactly (see InvestigateCommand.parseArgs's own reportOccurrenceIdEligible tracking).
# Blank lines in $1 are skipped, not turned into an empty --report value. Each path/id is
# preserved as its own array element via `+=(--report "$report")` -- never string-concatenated --
# so a value containing spaces is never subject to word-splitting, the same array-element
# discipline every other multi-value construction in this project already follows.
#
# $2 (report-occurrence-id, optional) is a second newline-separated list, applied strictly
# positionally against $1's own non-blank lines: line 1 of $2 pairs with the first report, line 2
# with the second, and so on. Unlike $1, a blank line in $2 is NOT skipped -- it means "no
# occurrence id for this position" (the same "some reports have one, some don't" shape
# InvestigateCommand's own reportOccurrenceIds list already allows, one nullable slot per report)
# -- skipping it instead would silently shift every later pairing out of position. $2 is entirely
# optional (omitted or blank): today's existing report-only behavior is then completely
# unchanged, including for callers that never pass a second argument at all.
#
# When $2 is non-blank, its own line count MUST exactly equal $1's non-blank report count --
# supplying occurrence ids without a matching, explicit report list to pair them against
# (including when $1 is blank entirely, e.g. report auto-discovery) is a caller configuration
# error, not a value this function can safely guess how to apply, so it fails loudly (a clear
# stderr message and a non-zero return) rather than silently mis-pairing or dropping data. This
# check runs regardless of installed axiom-version -- it is about the caller's own input being
# internally consistent, an orthogonal concern from whether the installed CLI understands
# --report-occurrence-id at all (that gating is the caller's responsibility, e.g. action.yml
# passing an empty $2 for an unsupported version, exactly like --execution-occurrence-id/
# --action-namespace's own already-established "silently withheld" precedent).
#
# Strips a trailing CR from each line before using it, for both $1 and $2. `read -r` only strips
# the trailing LF, not a preceding CR -- a CRLF-delimited value (verified directly: a value
# containing literal \r\n) would otherwise leave "report.xml\r" as the path, which fails file
# lookup silently different from a missing-file error. A genuine YAML `|` block scalar (the way
# report-file is normally authored) has its line endings normalized to LF by the YAML parser
# before action.yml ever sees it, but report-file's value isn't guaranteed to always arrive that
# way -- it could be populated from a prior step's output, or an explicit double-quoted YAML
# string with a literal \r\n escape, neither of which goes through block-scalar normalization.
# Cheap to handle unconditionally rather than assume the safe path is the only path.
build_report_args() {
  local report_input="$1"
  local occurrence_input="${2:-}"
  ARGS_REPORT=()

  local reports=()
  local report
  while IFS= read -r report; do
    report="${report%$'\r'}"
    if [ -n "$report" ]; then
      reports+=("$report")
    fi
  done <<< "$report_input"

  local occurrence_ids=()
  local has_occurrence_input=0
  if [ -n "$occurrence_input" ]; then
    has_occurrence_input=1
    # A here-string (<<<) always appends its own trailing newline on top of whatever the value
    # already ends with -- harmless for $report_input above (a wholly blank trailing line is
    # simply skipped, same as any other blank line), but occurrence_input's blank lines are
    # deliberately significant ("no id for this position"), so an unstripped double trailing
    # newline would manufacture one phantom extra empty line no caller ever wrote, silently
    # corrupting the cardinality check below. Stripping exactly one trailing newline first
    # (whether or not the value already had one) makes the read loop see exactly the lines the
    # caller actually authored, no more.
    local occurrence_lines_input="${occurrence_input%$'\n'}"
    local occurrence
    while IFS= read -r occurrence; do
      occurrence="${occurrence%$'\r'}"
      occurrence_ids+=("$occurrence")
    done <<< "$occurrence_lines_input"
  fi

  if [ "$has_occurrence_input" -eq 1 ] && [ "${#occurrence_ids[@]}" -ne "${#reports[@]}" ]; then
    echo "report-occurrence-id: expected ${#reports[@]} line(s) to pair positionally with" \
      "report-file's ${#reports[@]} explicit report(s), got ${#occurrence_ids[@]}" \
      "report-occurrence-id line(s) -- refusing to guess a pairing" >&2
    return 1
  fi

  local i
  for i in "${!reports[@]}"; do
    ARGS_REPORT+=(--report "${reports[$i]}")
    if [ "$has_occurrence_input" -eq 1 ] && [ -n "${occurrence_ids[$i]}" ]; then
      ARGS_REPORT+=(--report-occurrence-id "${occurrence_ids[$i]}")
    fi
  done
}

# Populates the global array ARGS_RUNTIME_LOG with alternating --runtime-log/<path> pairs, one
# pair per non-blank line of $1 -- the same newline-separated-list convention build_report_args
# already established for report-file, reused here rather than inventing a second one (docs/59
# §6). Blank input (the common case: no runtime-log-file supplied) produces an empty array, not
# an empty --runtime-log flag.
build_runtime_log_args() {
  ARGS_RUNTIME_LOG=()
  local log
  while IFS= read -r log; do
    log="${log%$'\r'}"
    if [ -n "$log" ]; then
      ARGS_RUNTIME_LOG+=(--runtime-log "$log")
    fi
  done <<< "$1"
}

# Populates the global array ARGS_RUNTIME_LOG_S3 with alternating --runtime-log-s3/<uri> pairs, one
# pair per non-blank line of $1 -- the same newline-separated-list convention reused a third time
# (docs/60-s3-runtime-log-acquisition-design.md §11). Each URI is an explicit s3://bucket/key
# supplied by the caller; this function does no S3-specific validation of its own -- a malformed
# URI still becomes exactly one --runtime-log-s3 argument, and InvestigateCommand's own collector
# is what turns a malformed value into a collection warning.
build_runtime_log_s3_args() {
  ARGS_RUNTIME_LOG_S3=()
  local uri
  while IFS= read -r uri; do
    uri="${uri%$'\r'}"
    if [ -n "$uri" ]; then
      ARGS_RUNTIME_LOG_S3+=(--runtime-log-s3 "$uri")
    fi
  done <<< "$1"
}

# Populates the global array ARGS_RUNTIME_LOG_GCS with alternating --runtime-log-gcs/<uri> pairs,
# one pair per non-blank line of $1 -- the same newline-separated-list convention reused a fourth
# time (docs/61-gcs-runtime-log-acquisition-design.md §11). Each URI is an explicit
# gs://bucket/object supplied by the caller; this function does no GCS-specific validation of its
# own -- a malformed URI still becomes exactly one --runtime-log-gcs argument, and
# InvestigateCommand's own collector is what turns a malformed value into a collection warning.
build_runtime_log_gcs_args() {
  ARGS_RUNTIME_LOG_GCS=()
  local uri
  while IFS= read -r uri; do
    uri="${uri%$'\r'}"
    if [ -n "$uri" ]; then
      ARGS_RUNTIME_LOG_GCS+=(--runtime-log-gcs "$uri")
    fi
  done <<< "$1"
}

# Populates the global array ARGS_RUNTIME_LOG_GITHUB_ACTIONS with alternating
# --runtime-log-github-actions-job/<jobId> pairs, one pair per non-blank line of $1 -- the same
# newline-separated-list convention reused a fifth time (docs/92-cross-source-investigation-
# phase3-github-actions-log-acquisition-design.md). Each job id is an explicit, caller-supplied
# value; this function does no job-id-specific validation of its own -- a malformed value still
# becomes exactly one --runtime-log-github-actions-job argument, and InvestigateCommand's own
# collector is what turns a malformed value into a collection warning.
build_runtime_log_github_actions_args() {
  ARGS_RUNTIME_LOG_GITHUB_ACTIONS=()
  local jobId
  while IFS= read -r jobId; do
    jobId="${jobId%$'\r'}"
    if [ -n "$jobId" ]; then
      ARGS_RUNTIME_LOG_GITHUB_ACTIONS+=(--runtime-log-github-actions-job "$jobId")
    fi
  done <<< "$1"
}

# Decision 3B S2, docs/71-github-action-shadow-mode-design.md §6a. Populates the global
# DERIVED_REPORT_OCCURRENCE_ID with one line per non-blank line of $2 (report-file), each
# "<$1>-report-<n>" where n is the 1-based position among only the non-blank lines -- counted
# exactly the way build_report_args itself counts report-file lines (blank lines skipped, CRLF
# stripped), so the resulting value's own line count always matches what build_report_args expects
# when it later pairs this value positionally against the same report-file input. $1 is the
# execution-occurrence-id already in effect for this invocation (manually supplied or itself
# derived) -- report-occurrence-id is deliberately keyed off whichever execution-occurrence-id
# actually applies, never the raw ungated run/attempt/job composite directly, so a caller who
# manually overrides execution-occurrence-id but leaves report-occurrence-id blank still gets a
# report-occurrence-id that's coherent with the identity actually in effect.
#
# M4.2b: a cheap, best-effort mirror of ReportGlobExpander.looksLikeGlob's own character set
# (*, ?, [, {) -- used only to decide whether THIS function should withhold its own derived id
# for one report-file line, never to decide whether axiom-cli itself treats a value as a glob
# (that authoritative decision -- including the "an existing literal file always wins, no matter
# what characters its name contains" rule -- is made once, in Java, by ReportGlobExpander itself).
# Being wrong in the conservative direction here (treating a literal, glob-looking filename as if
# it might expand) only costs that one report its auto-derived occurrence id, a low-stakes
# default-feature degradation, never a correctness bug -- unlike getting this wrong in Java, which
# would risk misapplying one id to several real documents (see build_report_args's own blank-line
# convention this reuses, and InvestigateCommand#expandReportPaths's own javadoc for why that
# would be a real identity bug, not a cosmetic one).
report_args_looks_like_glob() {
  case "$1" in
    *[\*\?\[\{]*) return 0 ;;
    *) return 1 ;;
  esac
}

# Deliberately does not skip blank lines within its own OUTPUT the way build_report_args skips
# blank INPUT lines -- there is no such thing as a "blank" derived value here (every non-blank
# report gets a well-formed line by construction) UNLESS that report line looks like a glob (M4.2b)
# -- see report_args_looks_like_glob above. A blank line in that one case reuses build_report_args's
# own existing "no id for this position" convention for occurrence_input, never a new one.
#
# M4.2b finding, confirmed real (not hypothetical): if the LAST derived line is blank (the final
# report-file line looked like a glob), build_report_args's own existing trailing-newline-
# stripping (there specifically to discard a here-string's own added trailing newline, not any
# meaningful data) collapses that intentional final blank line out of existence, miscounting this
# value's own line count by one and failing its cardinality check -- confirmed to be a pre-
# existing limitation of build_report_args itself (reproduced with a plain, hand-written
# "occ-a\n" input, nothing derived or glob-related at all), not introduced by glob support. Rather
# than change build_report_args's own already-tested contract, this function appends one extra
# trailing newline whenever its own last line is blank, which that stripping step then correctly
# removes, leaving exactly the intended blank final line behind -- confirmed to resolve the
# cardinality mismatch end to end, not merely asserted.
build_derived_report_occurrence_id() {
  local execution_occurrence_id="$1"
  local report_input="$2"
  DERIVED_REPORT_OCCURRENCE_ID=""
  local n=0
  local last_derived_was_blank=0
  local report
  while IFS= read -r report; do
    report="${report%$'\r'}"
    if [ -n "$report" ]; then
      n=$((n + 1))
      local derived=""
      if ! report_args_looks_like_glob "$report"; then
        derived="${execution_occurrence_id}-report-${n}"
      fi
      if [ "$n" -eq 1 ]; then
        DERIVED_REPORT_OCCURRENCE_ID="$derived"
      else
        DERIVED_REPORT_OCCURRENCE_ID="${DERIVED_REPORT_OCCURRENCE_ID}"$'\n'"$derived"
      fi
      if [ -z "$derived" ]; then
        last_derived_was_blank=1
      else
        last_derived_was_blank=0
      fi
    fi
  done <<< "$report_input"

  if [ "$last_derived_was_blank" -eq 1 ]; then
    DERIVED_REPORT_OCCURRENCE_ID="${DERIVED_REPORT_OCCURRENCE_ID}"$'\n'
  fi
}
