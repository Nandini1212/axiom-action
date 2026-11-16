#!/usr/bin/env bash
#
# verify-checksum.sh <file> <expected-sha256>
#
# Fails closed (stderr + nonzero exit) unless <file> exists and its own real SHA-256 content
# hash exactly matches <expected-sha256>. The expected value must itself look like a genuine
# SHA-256 digest (64 hex characters, case-insensitive) -- a missing, empty, or malformed expected
# value is refused outright, never silently treated as "nothing to compare against."
#
# CHECKSUM PROVENANCE: the caller is responsible for sourcing <expected-sha256> from the same
# trust boundary as <file> was downloaded from (e.g. the published .sha256 release asset sitting
# alongside the artifact itself) -- never recomputing it from the same bytes being verified here,
# which would make this check pass identically whether the download were genuine or tampered.
# See install-axiom.sh's own header for the full reasoning and what this does and does not prove.
#
# Reuses the exact cross-platform sha256sum/shasum selection idiom verify-distribution-
# artifact.sh's own checksum step already established, kept as its own small, focused script
# rather than folding into that one: that script's own calling contract (optional zip path,
# release-time license/compliance checks) is a different, unrelated responsibility from this
# one (verifying one already-downloaded file against one already-known expected value) -- the
# two must never be coupled just because they both compute a SHA-256 at some point.
set -euo pipefail

[ "$#" -ge 1 ] || { echo "Usage: verify-checksum.sh <file> <expected-sha256>" >&2; exit 1; }
FILE="$1"
# Deliberately `${2:-}`, not `${2:?...}`: an explicitly-empty expected value (e.g. an empty
# checksum asset read into a variable) must fail via the specific, well-formed-digest message
# below, not the generic usage message -- `:?` treats an empty string the same as a missing
# argument, which would otherwise mask that more specific, more actionable reason.
EXPECTED="${2:-}"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

[ -f "$FILE" ] || fail "file not found: $FILE"

EXPECTED="$(printf '%s' "$EXPECTED" | tr '[:upper:]' '[:lower:]')"
if ! [[ "$EXPECTED" =~ ^[0-9a-f]{64}$ ]]; then
  fail "expected checksum is not a well-formed SHA-256 digest (64 hex characters): '$EXPECTED'"
fi

if command -v sha256sum >/dev/null 2>&1; then
  actual="$(sha256sum "$FILE" | awk '{print $1}')"
else
  actual="$(shasum -a 256 "$FILE" | awk '{print $1}')"
fi

if [ "$actual" != "$EXPECTED" ]; then
  fail "checksum mismatch for $FILE -- expected $EXPECTED, got $actual"
fi
