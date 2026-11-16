#!/usr/bin/env bash
#
# safe-unzip.sh <zip-path> <dest-dir>
#
# Extracts <zip-path> into <dest-dir>, but only after confirming the archive is well-formed and
# contains no entry that is an absolute path, a path-traversal ("..") segment, a symlink, or an
# otherwise unusual (backslash-containing or control-character-containing) name. Defends against a
# maliciously crafted zip escaping the intended extraction directory (zip-slip) or planting a
# symlink that a later step could read or write through to reach somewhere outside <dest-dir>.
# Fails closed, before any file is written, if the archive is malformed or any entry is
# suspicious.
#
# Confirmed empirically, not assumed: a standard Info-ZIP `unzip` genuinely does extract a
# symlink entry as a real symlink pointing wherever the archive specifies, including an absolute
# path outside the destination directory. This check exists specifically because of that
# confirmed behavior, not a hypothetical one.
#
# Every archive-inspection command below has its own exit status checked explicitly via a
# captured variable, never via `< <(cmd)` process substitution or the non-final stage of a
# pipeline -- both of those hide a failing command's exit status from `set -e`/`pipefail`, which
# was confirmed directly: a corrupt/garbage "zip" fed through the previous
# `while ... done < <(unzip -Z1 "$ZIP")` form produced zero loop iterations and no error at all,
# silently treating a malformed archive as if it had no entries. `unzip -t` (full CRC integrity
# test) is also run first and explicitly checked, so a malformed/corrupt archive is rejected
# outright before any of its claimed entries are even trusted enough to list.
#
# Used by every unzip call site in this project (release.yml, install-axiom.sh,
# prepare-external-distribution.yml) -- one check, not three copies that could drift.
set -euo pipefail

ZIP="${1:?Usage: safe-unzip.sh <zip-path> <dest-dir>}"
DEST="${2:?Usage: safe-unzip.sh <zip-path> <dest-dir>}"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

[ -f "$ZIP" ] || fail "zip not found: $ZIP"

# Reject a malformed or corrupt archive outright, before trusting anything else about it. `-t`
# verifies every entry's CRC; `-Z1`/`-l` below do not, and can succeed enough to list entries
# even from an archive `unzip` would refuse (or behave unpredictably on) at real extraction time.
if ! unzip -t -q "$ZIP" > /dev/null; then
  fail "zip failed its integrity test, refusing to trust a malformed or corrupt archive: $ZIP"
fi

# -Z1 (zipinfo's "scripting" format) lists just the path of each entry, one per line. Captured
# into a variable first specifically so a failure to list (as opposed to a failure found while
# listing) is caught explicitly -- see the header comment on why process substitution cannot be
# trusted to surface this.
if ! listing="$(unzip -Z1 "$ZIP" 2>&1)"; then
  fail "unable to list zip entries, refusing to trust an unreadable archive: $listing"
fi
[ -n "$listing" ] || fail "zip contains no entries, refusing to extract: $ZIP"

while IFS= read -r entry; do
  [ -n "$entry" ] || continue
  case "$entry" in
    /*|[A-Za-z]:[/\\]*)
      fail "zip entry uses an absolute path, refusing to extract: $entry"
      ;;
    ..|../*|*/../*|*/..)
      fail "zip entry contains a '..' path-traversal segment, refusing to extract: $entry"
      ;;
    *'\'*)
      fail "zip entry contains a backslash, refusing to extract (ambiguous path separator): $entry"
      ;;
    *'^'*|*'?'*)
      # `unzip -Z1` itself replaces unprintable/control bytes in a name with a visible
      # substitute before we ever see it -- confirmed empirically: a literal tab (0x09) prints as
      # the two characters "^I", and DEL (0x7f) prints as a bare "?". A real filename containing
      # a literal caret or question mark is also unusual enough (and "?" is a shell glob
      # metacharacter besides) to refuse outright; we can't tell the two cases apart from this
      # listing, and neither should ever appear in a compiled CLI distribution's own file names.
      fail "zip entry contains a caret or question mark, which may be a substituted control character or an unusual literal name either way, refusing to extract: $entry"
      ;;
  esac
done <<< "$listing"

# zipinfo's long listing's first column is the Unix permission string; a symlink entry's first
# character is 'l' (e.g. "lrwxrwxrwx"), exactly like `ls -l`. Any symlink entry is refused -- a
# compiled CLI distribution has never legitimately needed one. Matched with bash's own `=~`
# rather than piping through awk/grep, so there is no secondary command whose failure could again
# be hidden by a pipeline.
if ! long_listing="$(zipinfo -l "$ZIP" 2>&1)"; then
  fail "unable to produce long zip listing, refusing to trust an unreadable archive: $long_listing"
fi

while IFS= read -r perm_line; do
  if [[ "$perm_line" =~ ^l[-rwxXsStT]{9} ]]; then
    fail "zip contains a symlink entry, refusing to extract: $perm_line"
  fi
done <<< "$long_listing"

mkdir -p "$DEST" || fail "unable to create destination directory: $DEST"
if ! unzip -q -o "$ZIP" -d "$DEST"; then
  fail "extraction failed partway through -- destination may contain partial content: $DEST"
fi
