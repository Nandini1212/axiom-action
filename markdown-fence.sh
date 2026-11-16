#!/usr/bin/env bash
#
# markdown-fence.sh -- sourced (not executed), defines write_fenced_summary_block.
#
# action.yml appends CLI report text to $GITHUB_STEP_SUMMARY inside a Markdown fenced code
# block. A fixed three-backtick fence -- the only kind ever used here before this file existed
# -- closes early the moment the content itself contains a run of three or more backticks on
# its own line. That is a real, reachable case, not a hypothetical one: a changed-file path is
# exactly the kind of content these reports render verbatim, backticks are legal in a POSIX
# filename, and a pull request's own author fully controls every filename in their own PR.
# Closing early lets the remainder of the report render as live Markdown/HTML in the step
# summary instead of literal text -- a visual-spoofing risk, not code execution or data
# exfiltration, but a real one.
#
# GFM allows an opening code-fence of any length >= 3 backticks; the matching closing fence
# must be at least that long. Using one more backtick than the longest run already present in
# the content is therefore always enough to make the fence unbreakable by anything the content
# itself contains -- no escaping, truncation, or rewriting of the content needed, and the
# rendered result is byte-for-byte identical to the previous fixed-three-backtick behavior for
# every report that does not contain such a run (the overwhelming majority of real reports).
#
# Deliberately does not `set -euo pipefail`: this file is sourced into an already-running
# script (action.yml's own run block, or a test harness), matching report-args.sh's own
# reasoning for the same choice.

# Prints the length of the longest run of consecutive '`' characters in $1 (0 if none).
#
# Greptile review finding (PR #179, confirmed real by direct measurement): the original
# implementation here extracted one character at a time via `${content:i:1}` in a bash loop --
# correct, but each substring extraction re-copies the string, making the whole scan effectively
# quadratic in the input length. Measured directly: ~5 seconds for a 50,000-character input.
# Every investigation now pays this cost on every run (this function runs unconditionally,
# whether or not pr-impact is even enabled), so a large report -- entirely plausible for a
# multi-failure investigation -- made this a real, user-visible regression, not a theoretical one.
#
# Delegates the scan to grep/awk/sort instead -- compiled tools doing the heavy lifting, no
# per-character bash loop at all: grep -o extracts every maximal run of backticks as its own
# match, awk measures each match's length, and sort -rn | head -1 keeps only the longest. Same
# contract, same result for every input this function was already tested against, dramatically
# faster for a large one.
longest_backtick_run() {
  local content="$1"
  local longest
  longest="$(printf '%s' "$content" | grep -o '`\{1,\}' | awk '{ print length }' | sort -rn | head -1)"
  echo "${longest:-0}"
}

# GitHub's own documented cap on $GITHUB_STEP_SUMMARY is 1 MiB per step -- not per write. Content
# beyond it fails the upload for the step's ENTIRE summary, losing every block already written in
# that step, not merely the overflow (confirmed directly against GitHub's own workflow-commands
# documentation, and independently measured: a real 741-changed-file pull request's own pr-impact
# report alone was ~292 KB; extrapolating linearly, one approaching GitHub's own 3,000-file cap
# would alone approach or exceed the full 1 MiB limit). 400,000 bytes leaves generous headroom for
# this call to coexist with at least one sibling write_fenced_summary_block call to the same file
# in the same step (e.g. the existing investigation's own summary, plus this one) while staying
# safely under that cap either way: two calls truncated to this bound, plus heading/fence/notice
# overhead (at most a few hundred bytes each -- see WRITE_FENCED_SUMMARY_BLOCK_MAX_FENCE_LEN
# below for the fence's own bound), sum to well under 1 MiB, not merely probably under it.
#
# A true BYTE count, deliberately not bash's own `${#content}` -- GitHub's own hosted Ubuntu
# runners default to a UTF-8 locale (C.UTF-8), under which bash's `${#var}`/`${var:offset:len}`
# count and slice by *character*, not by byte. Confirmed real by direct measurement under an
# explicit UTF-8 locale: 400,000 repetitions of a single 4-byte UTF-8 code point measured
# `${#content}` = 400,000 but `wc -c` = 1,600,000 -- 1.6 MiB from one call alone, already over
# the entire 1 MiB cap before ever combining with a second call. `wc -c`/`head -c` below are
# genuinely byte-oriented regardless of locale, giving a guarantee that holds for any content,
# not only ASCII content.
WRITE_FENCED_SUMMARY_BLOCK_MAX_BYTES=400000

# A sane, generous ceiling on the fence's own length, independent of
# WRITE_FENCED_SUMMARY_BLOCK_MAX_BYTES above. longest_backtick_run's result is normally bounded
# by something far smaller in practice -- no real POSIX filename can contain more consecutive
# backticks than the filesystem's own path-component length limit (255 bytes on every filesystem
# this Action could realistically encounter) -- but this is a belt-and-suspenders bound on the
# fence computation itself, not something that relies on that assumption holding: without it, a
# content string that was somehow almost entirely backticks could make the fence itself (written
# twice, open and close) grow without any upper bound at all, independent of the byte cap above
# (which bounds $content, not the fence this function builds from it).
WRITE_FENCED_SUMMARY_BLOCK_MAX_FENCE_LEN=1000

# Appends "## $1" followed by $2's own content, inside a Markdown fenced code block long enough
# that no run of backticks within $2 can close it early, to $GITHUB_STEP_SUMMARY. $3 is the
# fence's own language tag (e.g. "text"); defaults to "text", matching every existing heading
# this Action already writes. $2 is truncated first (see
# WRITE_FENCED_SUMMARY_BLOCK_MAX_BYTES above) when it alone risks the step's own 1 MiB cap --
# always with an explicit, visible notice of exactly how many bytes were cut, never silently.
write_fenced_summary_block() {
  local heading="$1"
  local content="$2"
  local lang="${3:-text}"
  local content_bytes
  content_bytes="$(printf '%s' "$content" | wc -c | tr -d ' ')"

  if [ "$content_bytes" -gt "$WRITE_FENCED_SUMMARY_BLOCK_MAX_BYTES" ]; then
    # head -c cuts at an exact byte offset, regardless of locale -- it may split a multi-byte
    # UTF-8 character in half at that exact boundary (a possible single garbled character right
    # at the cut point), which is a cosmetic imperfection only, never a size-safety one: the
    # byte count after this line is exactly WRITE_FENCED_SUMMARY_BLOCK_MAX_BYTES, provably, not
    # merely probably. Deliberately through a temp file, not a `printf | head -c` pipe: `head -c`
    # closes its input as soon as it has enough bytes, and when $content is much larger than the
    # bound, the still-writing printf on the other end of that pipe then fails with SIGPIPE --
    # under a caller running with `set -o pipefail` (this file's own test harness does, and any
    # future caller might), that failure propagates as this whole function call's own failure,
    # even though the truncated result it already produced was correct. Reading from a real file
    # instead of a live pipe has no writer left to break.
    local truncate_tmp_file
    truncate_tmp_file="$(mktemp)"
    printf '%s' "$content" > "$truncate_tmp_file"
    content="$(head -c "$WRITE_FENCED_SUMMARY_BLOCK_MAX_BYTES" "$truncate_tmp_file")"
    rm -f "$truncate_tmp_file"
    content="${content}"$'\n\n'"... (truncated: showing the first $WRITE_FENCED_SUMMARY_BLOCK_MAX_BYTES of $content_bytes bytes -- the full report exceeded what can safely be written to this job summary)"
  fi

  local longest
  longest="$(longest_backtick_run "$content")"
  [ "$longest" -gt "$WRITE_FENCED_SUMMARY_BLOCK_MAX_FENCE_LEN" ] && longest="$WRITE_FENCED_SUMMARY_BLOCK_MAX_FENCE_LEN"
  local fence_len=$((longest + 1))
  [ "$fence_len" -lt 3 ] && fence_len=3
  local fence=""
  local i
  for ((i = 0; i < fence_len; i++)); do
    fence="${fence}\`"
  done

  {
    echo "## $heading"
    echo "${fence}${lang}"
    echo "$content"
    echo "$fence"
  } >> "$GITHUB_STEP_SUMMARY"
}
