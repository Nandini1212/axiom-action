#!/usr/bin/env bash
#
# install-axiom.sh <version> [install-dir]
#
# Installs the Axiom CLI and prints the path to the installed `axiom` binary on stdout.
# `action.yml` calls this script and uses only that printed path -- it has no knowledge of *how*
# a version is obtained. Today that means downloading a GitHub Release asset via the `gh` CLI
# (this script's own body); a future version could instead resolve the same version from Maven,
# Homebrew, a Docker image, or an internal mirror without action.yml or any consumer's workflow
# changing at all. See docs/24-github-action-design.md §3.
#
# Uses `gh release download`, not a plain `curl` against the public download URL: while the
# repository is private, downloading a release asset requires authentication -- a plain URL 404s
# for an unauthenticated request exactly the way the repository itself does. `gh` picks up
# GH_TOKEN/GITHUB_TOKEN automatically (already set by every GitHub Actions job, and by `gh auth
# login` for a developer's own machine), so no separate curl-auth-header logic is needed here. If
# the repository is ever made public, this still works unchanged -- `gh` degrades gracefully to
# an unauthenticated request when no token is set and the repo allows it.
#
# The release asset's filename is read from RELEASE_ASSET_NAME, a sibling file in this same
# directory -- release.yml reads the identical file, so the two never rely on a name that's
# merely documented to match; it's read from one place.
#
# RELEASE INSTALLATION INTEGRITY (H2a): every download whose release actually published an
# "${ASSET_NAME}.sha256" sibling asset is verified against it (minted by release.yml itself,
# right after that exact artifact passed its own license/content gate -- see
# verify-distribution-artifact.sh) before extraction, and extraction happens into a private
# staging directory that is only ever made visible at its final path via one atomic rename,
# after that verification succeeds. A cached install is trusted on a later call only if its own
# extracted tree's own content hash still matches the one recorded in this script's own
# completion marker at install time -- never merely because axiom/bin/axiom happens to exist and
# be executable at the expected path, which could be a leftover from a prior run that crashed
# mid-extraction, content placed there by anything other than this script, or a file silently
# modified in place afterward while keeping its executable bit (confirmed as a real review
# finding against an earlier version of this check, which only looked at bin/axiom's own
# existence/executability plus the marker's bare presence -- neither catches a modified sibling
# file, e.g. under lib/, or a modified bin/axiom that keeps its executable bit).
#
# TWO-TIER POLICY, DELIBERATE: a MISMATCHED or MALFORMED checksum always fails closed,
# unconditionally -- that is the one shape that can only mean the downloaded bytes are not what
# was published, or that the checksum asset itself is not genuinely absent but corrupt/truncated
# (an empty-but-present .sha256 file is treated as malformed, not as "missing" -- see
# verify-checksum.sh's own validation). A release with NO checksum asset at all is different, but
# ONLY for a version below v1.11.0: release.yml's own "Verify the packaged artifact" step is not
# conditional -- a release genuinely cannot be published through that pipeline today without a
# matching checksum also being minted and uploaded alongside it in the same `gh release create`
# call, so a asset that never existed in the first place means only one thing for a version that
# predates v1.11.0, when that step was introduced (confirmed directly: v1.0.0 through v1.10.0
# carry no .sha256 asset at all; v1.11.0 onward always do). This exception is checked against the
# requested version number itself, never merely "a checksum happened to not be found this time" --
# a v1.11.0-or-later version with a missing checksum asset still fails closed exactly like a
# mismatch, since for that version range a missing asset can only mean a failed/incomplete
# download, a release published outside the normal pipeline, or something else genuinely wrong --
# never the legacy case, and it must never be silently treated as if it were. Failing closed
# unconditionally for every missing checksum, with no version-aware exception at all, would make
# 17 of this project's own 22 published releases permanently uninstallable -- including versions
# README still documents as the stated minimum for specific features, and the one this
# repository's own hosted smoke test deliberately pins to for legacy-compatibility coverage. So a
# pre-v1.11.0 release with no checksum asset at all instead prints a clear, visible warning and
# installs unverified -- exactly the same trust
# level every version of this script had for every version before this change, never silently.
#
# CONCURRENCY: a per-install-directory lock (plain `mkdir`, portable, no flock dependency) is
# held across the entire cache-check-through-marker-write sequence below, so two overlapping
# invocations for the same version/install-dir (e.g. concurrent jobs on a self-hosted runner
# sharing a HOME) can never interleave -- one completes (or fails) entirely before the other's
# own cache check even runs, so a second caller never deletes an install the first is already
# using, and never needs to re-download if the first caller just finished verifying it.
#
# Deliberately NO automatic stale-lock recovery. An earlier version of this script tried to
# detect and reclaim a lock abandoned by a killed process (checking a recorded pid's liveness,
# then reclaiming via an atomic rename) -- confirmed, on review, to still be unsafe: atomic
# rename only guarantees that two callers can't both successfully rename the exact same
# still-existing target; it says nothing about a caller acting on a *stale decision* made before
# the target was legitimately replaced. Concretely: caller A reads a dead pid and decides
# "stale"; caller B, in the meantime, fully reclaims the lock, deletes it, and recreates a live
# one of its own; A's own rename, executing afterward, still blindly grabs whatever currently
# sits at that path -- now B's live lock -- with no way to tell it apart from the stale one A
# originally observed. Every attempted fix to that (re-verify after grabbing, put it back if
# wrong, etc.) only moved the same race somewhere else. Rather than keep accumulating custom
# locking logic to chase it, the stale-recovery feature is removed entirely: `mkdir`'s own
# atomicity (one syscall, no read-then-act gap at all) is the only thing this script depends on
# for correctness. A lock that is never released (the holding process killed in a way that
# bypasses the EXIT trap below, e.g. SIGKILL, an OOM kill, a forcibly terminated runner instance)
# makes a later call for that version/install-dir fail after a bounded wait, with a clear,
# actionable message naming the recorded pid (kept only as diagnostic text now, never acted on)
# -- a human can confirm that process is gone and remove the lock directory by hand. This mirrors
# established prior art (e.g. dpkg/apt's own lock files behave the same way) and trades a rare
# need for manual intervention for the complete absence of this entire class of race. A
# GitHub-hosted ephemeral runner is unaffected either way: the whole $HOME disappears with a
# killed VM, so it can never leave a stale lock behind in the first place.
#
# CHECKSUM PROVENANCE AND ITS LIMITS: the expected checksum comes from the exact same GitHub
# Release, uploaded by the exact same release.yml run, as the artifact it verifies -- the same
# trust boundary, not an independent one (see release.yml's own "Verify the packaged artifact"
# step, which mints and uploads both files together in one `gh release create` call). This
# guarantees the bytes installed here are byte-for-byte identical to what that release actually
# published -- it catches transport corruption, a truncated/partial download, and a wrong asset
# being served. It does NOT guarantee that what was published is itself trustworthy: a release
# pipeline compromised before or during that same workflow run (a malicious tag push, a
# compromised GITHUB_TOKEN, a compromised runner) would produce a malicious zip and a genuinely
# matching checksum for it, since both come from the same compromised process. Defending against
# that would need an independent provenance mechanism (e.g. artifact signing with a key never
# present on the build runner, or a keyless/transparency-log scheme) -- out of scope here; this
# script's own guarantee is integrity-in-transit against the published release, not authenticity
# of the release itself. Repository-level controls (tag/branch protection, required reviews on
# workflow changes) are this project's actual defense against a compromised release process, and
# are outside what any install-time script can verify.
set -euo pipefail

# Overridable only so a separate distribution package (e.g. a public wrapper Action that mirrors
# this project's own verified release artifacts into its own public GitHub Releases) can reuse
# this exact script unmodified against its own repository, rather than forking it. Never intended
# to be set by a normal caller of this repository's own action.yml, which never sets it and so
# always gets this same default.
REPOSITORY="${AXIOM_RELEASE_REPOSITORY:-Nandini1212/axiom}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ASSET_NAME="$(cat "${SCRIPT_DIR}/RELEASE_ASSET_NAME")"

VERSION="${1:?Usage: install-axiom.sh <version> [install-dir]}"
INSTALL_DIR="${2:-$HOME/.axiom/$VERSION}"
MARKER="$INSTALL_DIR/.install-verified-sha256"
PARENT_DIR="$(dirname "$INSTALL_DIR")"
LOCK_DIR="${INSTALL_DIR}.lock"
# Overridable only for this script's own test suite, to exercise the timeout path without a
# real 60-second wait -- never intended to be set by a real caller.
LOCK_TIMEOUT_SECONDS="${AXIOM_INSTALL_LOCK_TIMEOUT_SECONDS:-60}"

# Composite content hash of every file in a directory tree -- deliberately never just
# axiom/bin/axiom alone: that launcher script does not change between versions sharing the same
# release tooling, so hashing it alone would not catch a modified sibling file (e.g. under
# lib/). Absolute paths are dropped before the final hash (awk '{print $1}') so this produces
# the same value for the same content regardless of where the tree happens to be rooted on disk
# -- confirmed necessary, since the two calls below compare a freshly extracted staging copy
# against the already-installed one at a different path.
hash_tree() {
  local sha_cmd
  if command -v sha256sum >/dev/null 2>&1; then
    sha_cmd="sha256sum"
  else
    sha_cmd="shasum -a 256"
  fi
  find "$1" -type f -print0 | sort -z | xargs -0 $sha_cmd | awk '{print $1}' | $sha_cmd | awk '{print $1}'
}

# True iff $1 (e.g. "v1.11.0") is v1.11.0 or later -- the fixed historical point release.yml's
# own checksum-minting step was introduced, never a moving target (see the TWO-TIER POLICY note
# above for why this must be checked against the version number itself, not just "was a checksum
# found this time"). Plain numeric comparison per component, not a string comparison -- "v1.9.0"
# sorts after "v1.11.0" as a string, which would be wrong. A version string that doesn't parse as
# plain numeric major/minor (never expected in practice -- real tags are always vMAJOR.MINOR.PATCH)
# deliberately defaults to true (treated as "at least v1.11.0", i.e. the fail-closed-on-missing-
# checksum branch) rather than silently falling into the legacy warn-and-proceed exception.
version_at_least_v1_11_0() {
  local v="${1#v}" major minor
  IFS='.' read -r major minor _ <<< "$v"
  if ! [[ "$major" =~ ^[0-9]+$ ]] || ! [[ "$minor" =~ ^[0-9]+$ ]]; then
    return 0
  fi
  if [ "$major" -ne 1 ]; then
    [ "$major" -gt 1 ]
    return
  fi
  [ "$minor" -ge 11 ]
}

# A per-install-directory lock, held for this entire script's body (released via the trap set
# immediately below, which fires on any exit) -- serializes every invocation for the same
# version/install-dir, so two overlapping callers (e.g. concurrent jobs on a self-hosted runner
# sharing a HOME) can never interleave: the second caller's own cache check never runs until the
# first has fully finished (or failed), so it never deletes an install the first is still using,
# and sees the first's own completed, now-valid install if one just landed. `mkdir` is used as
# the lock primitive specifically because it is atomic and portable (no flock dependency, which
# is Linux-only via util-linux and unavailable on a developer's own macOS machine -- this script
# is documented to run there too).
#
# $PARENT_DIR must exist before the lock directory can ever be created inside it -- confirmed as
# a real bug against an earlier version of this change: on a genuinely first-ever install (e.g.
# $HOME/.axiom not yet existing at all on a fresh runner), plain `mkdir "$LOCK_DIR"` fails every
# time with no such parent directory, so the loop below span its own full timeout and failed
# unconditionally, even with no real contention whatsoever.
mkdir -p "$PARENT_DIR"

# `mkdir` alone is the entire mechanism: one syscall, atomically either creates the directory
# (lock acquired) or fails because it already exists (lock held by someone else) -- no
# read-then-act gap for a race to hide in. The pid file is written only as diagnostic text for
# the timeout message below; nothing in this script ever makes a decision based on reading it
# back.
waited=0
until mkdir "$LOCK_DIR" 2>/dev/null; do
  if [ "$waited" -ge "$LOCK_TIMEOUT_SECONDS" ]; then
    held_by="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
    echo "Timed out after ${LOCK_TIMEOUT_SECONDS}s waiting for another install-axiom.sh invocation for $VERSION at $INSTALL_DIR to finish (lock held by pid ${held_by:-unknown}). If you are certain that process is no longer running, remove $LOCK_DIR and retry." >&2
    exit 1
  fi
  sleep 1
  waited=$((waited + 1))
done
echo "$$" > "$LOCK_DIR/pid"

STAGING=""
cleanup() {
  [ -n "$STAGING" ] && rm -rf "$STAGING"
  rm -rf "$LOCK_DIR"
}
trap cleanup EXIT

# A cached install is trusted only when the binary is executable, a marker exists, *and* the
# installed tree's own content, re-hashed right now, still matches the hash this script itself
# recorded the moment it finished installing it. The first two alone are not enough: a crash
# partway through a previous install can leave a real, executable axiom/bin/axiom behind without
# ever reaching the point the marker is written (see the atomic rename below); and neither alone
# nor together catch a file modified in place afterward (e.g. a corrupted lib/ jar, or bin/axiom
# itself edited while keeping its executable bit) -- only re-verifying the tree's own current
# content against what was actually installed catches that.
if [ -x "$INSTALL_DIR/axiom/bin/axiom" ] && [ -s "$MARKER" ]; then
  RECORDED_TREE_HASH="$(tail -n1 "$MARKER")"
  if [ "$(hash_tree "$INSTALL_DIR/axiom")" = "$RECORDED_TREE_HASH" ]; then
    echo "$INSTALL_DIR/axiom/bin/axiom"
    exit 0
  fi
fi

# Anything short of that is untrusted -- wipe it outright rather than extracting on top of
# unknown leftover content (a stale or partial previous attempt, content modified after a prior
# successful install, or a directory populated by anything other than this script's own verified
# pipeline). Every byte this script ever executes comes only from the fresh download performed
# below.
rm -rf "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR"

STAGING="$(mktemp -d "${PARENT_DIR}/.axiom-install-XXXXXX")"

gh release download "$VERSION" \
  --repo "$REPOSITORY" \
  --pattern "$ASSET_NAME" \
  --pattern "${ASSET_NAME}.sha256" \
  --dir "$STAGING" \
  --clobber

[ -f "$STAGING/$ASSET_NAME" ] || {
  echo "No $ASSET_NAME asset found for $VERSION in $REPOSITORY" >&2
  exit 1
}

# Tested for existence, not non-emptiness: an empty-but-*present* .sha256 asset is never the
# "this version predates the mechanism" shape (that shape is a release with NO such asset at
# all) -- it is a malformed/corrupt checksum, which must fail closed exactly like a mismatch,
# never be silently treated the same as a version that simply never had one. verify-checksum.sh
# itself rejects an empty (or otherwise not-well-formed) expected value, so routing it there
# rather than into the warn-and-skip branch is what makes that failure actually happen.
#
# A missing checksum asset for a v1.11.0-or-later version is NOT the legacy case -- it fails
# closed exactly like a mismatch, since release.yml's own publish gate makes that shape mean
# something is genuinely wrong (a failed/incomplete download, or a release published outside the
# normal pipeline), never "this version simply predates the mechanism."
if [ -f "$STAGING/${ASSET_NAME}.sha256" ]; then
  EXPECTED_SHA256="$(tr -d '[:space:]' < "$STAGING/${ASSET_NAME}.sha256")"
  "${SCRIPT_DIR}/verify-checksum.sh" "$STAGING/$ASSET_NAME" "$EXPECTED_SHA256"
  ZIP_VERIFICATION_NOTE="$EXPECTED_SHA256"
elif version_at_least_v1_11_0 "$VERSION"; then
  echo "No ${ASSET_NAME}.sha256 checksum asset was found for $VERSION, which should have one -- every release since v1.11.0 publishes one through release.yml's own gate. This may mean the download failed, or that this release was not published through the normal pipeline; it is never treated as the pre-v1.11.0 legacy exception. Refusing to install an unverified artifact." >&2
  exit 1
else
  echo "Warning: no ${ASSET_NAME}.sha256 checksum asset was published for $VERSION -- this release predates this project's release-integrity mechanism (introduced at v1.11.0). Installing without checksum verification, exactly as every version of this script did before this change." >&2
  ZIP_VERIFICATION_NOTE="unverified ($VERSION predates the release-integrity mechanism)"
fi

EXTRACTED="$STAGING/extracted"
"${SCRIPT_DIR}/safe-unzip.sh" "$STAGING/$ASSET_NAME" "$EXTRACTED"

if [ ! -x "$EXTRACTED/axiom/bin/axiom" ]; then
  echo "Extracted $ASSET_NAME does not contain an executable axiom/bin/axiom" >&2
  exit 1
fi

# Computed from the staging copy before it is ever moved into place -- this is the value every
# later invocation's own cache check re-derives from $INSTALL_DIR/axiom and compares against.
TREE_HASH="$(hash_tree "$EXTRACTED/axiom")"

# The one point this install becomes visible at its real path -- a same-filesystem rename
# (STAGING was created under $PARENT_DIR specifically so this is a true rename, not a recursive
# copy), so there is no window in which $INSTALL_DIR/axiom exists in a partially-written state.
mv "$EXTRACTED/axiom" "$INSTALL_DIR/axiom"

# Written strictly after the rename above succeeds. Two lines: the zip-level verification note
# (the verified zip checksum, or the explicit "unverified" sentinel set above) purely as
# human-readable audit context for anyone who looks at this file directly, and the tree hash on
# its own final line, which is the one value a later call's cache check actually reads back and
# re-verifies (see "tail -n1" above) -- never recomputed from the note on the first line.
{
  printf '%s\n' "$ZIP_VERIFICATION_NOTE"
  printf '%s\n' "$TREE_HASH"
} > "$MARKER"

echo "$INSTALL_DIR/axiom/bin/axiom"
