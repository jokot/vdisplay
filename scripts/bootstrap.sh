#!/usr/bin/env bash
# Bootstrap upstream submodules for the vdisplay monorepo.
#
# Subtree squash drops submodule SHA pinning, so we re-derive submodules
# from each subtree's .gitmodules and clone them at HEAD of the declared
# branch (default: master). Idempotent — skips already-cloned paths.
#
# Behaviour:
#   - Per-platform skip list (Sunshine has many Linux/Win-only submodules
#     that aren't needed for a macOS build, plus Sunshine's CMake fetches
#     prebuilt FFmpeg via FetchContent so the FFmpeg-source build-deps
#     submodule chain isn't needed on any platform for a default build).
#   - Retries each clone up to RETRIES times with sleeps in between
#     (boarding-house wifi friendly).
#   - Manual recursion (does NOT pass --recurse-submodules to clone), so
#     skip rules apply at every nesting depth.
#
# Usage:
#   ./scripts/bootstrap.sh             # auto-detect platform via uname
#   PLATFORM=linux ./scripts/bootstrap.sh
#   RETRIES=5 ./scripts/bootstrap.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RETRIES="${RETRIES:-3}"
RETRY_SLEEP="${RETRY_SLEEP:-5}"
PLATFORM="${PLATFORM:-$(uname -s | tr '[:upper:]' '[:lower:]')}"

# Subtrees to bootstrap.
SUBTREES=(
  "upstream/host"
  "upstream/client-desktop"
  "upstream/client-android"
)

# Path-substring patterns that should NEVER be cloned, regardless of platform.
# build-deps recursively pulls FFmpeg + x264 + x265 + Vulkan source — many GBs;
# Sunshine's CMake fetches prebuilt FFmpeg via FetchContent so it's unused for
# a default build of any platform.
SKIP_ALL=(
  "third-party/build-deps"
)

# macOS-only skip list.
# Keep nv-codec-headers — Sunshine compiles its NVENC path on every platform,
# the headers are tiny, and skipping them breaks the build.
SKIP_DARWIN=(
  "packaging/linux/"
  "third-party/wayland-protocols"
  "third-party/wlr-protocols"
  "third-party/nvapi"
  "third-party/ViGEmClient"
)

# Linux-only skip list (no Win/Mac-specific deps).
SKIP_LINUX=(
  "third-party/nvapi"
  "third-party/ViGEmClient"
)

# Windows / MSYS skip list.
SKIP_WIN=(
  "packaging/linux/"
  "third-party/wayland-protocols"
  "third-party/wlr-protocols"
)

case "$PLATFORM" in
  darwin)              SKIP_PATTERNS=("${SKIP_ALL[@]}" "${SKIP_DARWIN[@]}") ;;
  linux)               SKIP_PATTERNS=("${SKIP_ALL[@]}" "${SKIP_LINUX[@]}") ;;
  msys*|mingw*|cygwin*) SKIP_PATTERNS=("${SKIP_ALL[@]}" "${SKIP_WIN[@]}") ;;
  *)                   SKIP_PATTERNS=("${SKIP_ALL[@]}") ;;
esac

echo "Platform: $PLATFORM"
echo "Skip patterns: ${SKIP_PATTERNS[*]}"
echo

should_skip() {
  local path="$1"
  for pat in "${SKIP_PATTERNS[@]}"; do
    if [[ "$path" == *"$pat"* ]]; then
      return 0
    fi
  done
  return 1
}

# Clone a single repo with retry. Does NOT recurse into nested submodules —
# the caller handles recursion so skip rules apply at every depth.
clone_with_retry() {
  local url="$1" branch="$2" target="$3"
  local attempt=1
  while (( attempt <= RETRIES )); do
    if [[ -n "$branch" ]]; then
      if git clone --depth 1 --branch "$branch" --no-recurse-submodules "$url" "$target"; then
        return 0
      fi
    else
      if git clone --depth 1 --no-recurse-submodules "$url" "$target"; then
        return 0
      fi
    fi
    echo "  ! clone failed (attempt $attempt/$RETRIES): $url"
    rm -rf "$target"
    (( attempt++ ))
    if (( attempt <= RETRIES )); then
      sleep "$RETRY_SLEEP"
    fi
  done
  echo "  ✗ giving up: $url"
  return 1
}

# Recurse: read .gitmodules in $1, clone each non-skipped submodule, then
# recurse into the clone (which may have its own .gitmodules).
clone_submodules_in() {
  local dir="$1"
  local rel_prefix="${2:-}" # path relative to its enclosing subtree, for skip-matching
  local gitmodules="$dir/.gitmodules"

  [[ -f "$gitmodules" ]] || return 0

  local names
  names="$(git config -f "$gitmodules" --name-only --get-regexp '^submodule\..*\.path$' 2>/dev/null \
            | sed -E 's/^submodule\.(.*)\.path$/\1/' || true)"

  while IFS= read -r name; do
    [[ -z "$name" ]] && continue

    local path url branch
    path="$(git config -f "$gitmodules" --get "submodule.$name.path")"
    url="$(git config -f "$gitmodules"  --get "submodule.$name.url")"
    branch="$(git config -f "$gitmodules" --get "submodule.$name.branch" 2>/dev/null || echo "")"

    local match_path="${rel_prefix:+$rel_prefix/}$path"
    local target="$dir/$path"

    if should_skip "$match_path"; then
      echo "  - skip $match_path (platform filter)"
      continue
    fi

    if [[ -d "$target/.git" || -f "$target/.git" ]]; then
      echo "  ✓ $match_path (already cloned)"
    elif [[ -d "$target" && -n "$(ls -A "$target" 2>/dev/null || true)" ]]; then
      echo "  ! $match_path exists non-empty, not a git repo — skipping"
      continue
    else
      mkdir -p "$(dirname "$target")"
      echo "  + cloning $url${branch:+ ($branch)} -> $match_path"
      if ! clone_with_retry "$url" "$branch" "$target"; then
        continue
      fi
    fi

    # Recurse into newly cloned submodule
    clone_submodules_in "$target" "$match_path"
  done <<< "$names"
}

failed=0
echo "Bootstrapping vdisplay subtree submodules..."
for sub in "${SUBTREES[@]}"; do
  full="$REPO_ROOT/$sub"
  if [[ ! -d "$full" ]]; then
    echo "  - $sub not present, skipping"
    continue
  fi
  echo
  echo "[$sub]"
  clone_submodules_in "$full" "" || failed=1
done

echo
if (( failed )); then
  echo "Done with errors — re-run when network stabilises."
  exit 1
else
  echo "Done."
fi
