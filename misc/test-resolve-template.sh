#!/usr/bin/env bash
# test-resolve-template.sh
# Improved test harness to validate template download URLs used by misc/create_lxc.sh
# Features:
#  - Accepts one or more TEMPLATE_VARIANT values
#  - Supports overrides: GITHUB_REPO (owner/repo) and MOCK_FILE (local JSON)
#  - Validates Debian GitHub release asset resolution and non-debian Jenkins URL
#  - Checks HTTP status of resolved URLs
#
# Usage examples:
#  VERBOSE=yes ./test-resolve-template.sh --repo the-guong/debian-ifupdown2-lxc bookworm
#  ./test-resolve-template.sh --mock-file ./misc/mock_release.json bookworm,bullseye

set -euo pipefail

VERBOSE=${VERBOSE:-no}
GITHUB_REPO=${GITHUB_REPO:-asylumexp/debian-ifupdown2-lxc}
MOCK_FILE=${MOCK_FILE:-}

dbg() { [[ "$VERBOSE" == "yes" ]] && printf "[DEBUG] %s\n" "$*"; }

usage() {
  cat <<EOF
Usage: $0 [options] <variant[,variant,...]>

Options:
  --repo OWNER/REPO    GitHub repo to query for Debian assets (default: $GITHUB_REPO)
  --mock-file FILE     Use local JSON file instead of GitHub API (for offline testing)
  --verbose            Enable debug output (or set VERBOSE=yes env)
  -h, --help           Show this message

Examples:
  VERBOSE=yes $0 --repo the-guong/debian-ifupdown2-lxc bookworm
  $0 --mock-file ./misc/mock_release.json bookworm,bullseye
EOF
}

if [[ ${1:-} == "--help" || ${1:-} == "-h" ]]; then
  usage
  exit 0
fi

# Parse optional flags
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      GITHUB_REPO=${2:-}
      shift 2
      ;;
    --mock-file)
      MOCK_FILE=${2:-}
      shift 2
      ;;
    --verbose)
      VERBOSE=yes
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    --*)
      echo "Unknown option: $1" >&2
      usage
      exit 2
      ;;
    *)
      # first non-option is variant(s)
      VARIANTS_RAW=$1
      shift
      # accept only first non-option
      break
      ;;
  esac
done

VARIANTS_RAW=${VARIANTS_RAW:-bookworm}
IFS=',' read -r -a VARIANTS <<<"$VARIANTS_RAW"

dbg "GITHUB_REPO=$GITHUB_REPO"
dbg "MOCK_FILE=${MOCK_FILE:-<none>}"
dbg "VARIANTS=${VARIANTS[*]}"

curl_cmd() {
  if command -v curl >/dev/null 2>&1; then
    curl -sS "$@"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO- "$@"
  else
    echo "No curl or wget available" >&2
    return 2
  fi
}

check_url() {
  local url=$1
  dbg "Checking URL: $url"
  # Use curl if available to follow redirects and get http code
  if command -v curl >/dev/null 2>&1; then
    http_code=$(curl -s -o /dev/null -w "%{http_code}" -L "$url" || true)
    rc=$?
    dbg "curl exit=$rc http_code=$http_code"
    if [[ $rc -ne 0 ]]; then
      printf "FAIL: %s -> curl failed (exit %s)\n" "$url" "$rc"
      return 2
    fi
    if [[ $http_code -ge 200 && $http_code -lt 400 ]]; then
      printf "OK:   %s -> HTTP %s\n" "$url" "$http_code"
      return 0
    else
      printf "FAIL: %s -> HTTP %s\n" "$url" "$http_code"
      return 1
    fi
  else
    # Fallback: try wget --spider
    if command -v wget >/dev/null 2>&1; then
      if wget --spider -q --max-redirect=10 "$url"; then
        printf "OK:   %s -> wget spider OK\n" "$url"
        return 0
      else
        printf "FAIL: %s -> wget spider failed\n" "$url"
        return 1
      fi
    fi
  fi
}

exit_code=0

# Prepare release JSON source (GitHub API or mock file)
if [[ -n "$MOCK_FILE" ]]; then
  if [[ ! -f "$MOCK_FILE" ]]; then
    echo "Mock file '$MOCK_FILE' not found" >&2
    exit 2
  fi
  release_json_src="file://$MOCK_FILE"
else
  release_json_src="https://api.github.com/repos/$GITHUB_REPO/releases/latest"
fi

for var in "${VARIANTS[@]}"; do
  var_trimmed=$(printf "%s" "$var" | tr -d '[:space:]')
  [[ -z "$var_trimmed" ]] && continue
  printf "\n== Variant: %s ==\n" "$var_trimmed"

  # Debian-like resolution: look up GitHub release assets
  dbg "Fetching release JSON from $release_json_src"
  if [[ -n "$MOCK_FILE" ]]; then
    release_json=$(cat "$MOCK_FILE") || release_json=""
  else
    release_json=$(curl -sS "$release_json_src" || true)
  fi

  if [[ -z "$release_json" ]]; then
    echo "No release JSON returned (repo or release may not exist): $release_json_src"
    exit_code=3
    continue
  fi

  # Try exact match first (like create_lxc.sh) for arm64 rootfs assets
  dl_url=$(printf "%s" "$release_json" | grep -E 'browser_download_url' | grep -Ei "debian-${var_trimmed}.*arm64.*rootfs.*\\.(tar\\.xz|tar\\.gz|tar)" | cut -d\" -f4 || true)
  if [[ -z "$dl_url" ]]; then
    # Fallback: any debian-.* arm64 rootfs asset
    dl_url=$(printf "%s" "$release_json" | grep -E 'browser_download_url' | grep -Ei "debian-.*arm64.*rootfs.*\\.(tar\\.xz|tar\\.gz|tar)" | cut -d\" -f4 || true)
  fi

  if [[ -z "$dl_url" ]]; then
    echo "No matching GitHub asset found for debian-$var_trimmed (repo: $GITHUB_REPO)"
    # Also check the Jenkins-style fallback used in create_lxc.sh for non-debian OSes (construct it anyway)
    jenkins_url="https://jenkins.linuxcontainers.org/job/image-debian/architecture=arm64,release=$var_trimmed,variant=default/lastStableBuild/artifact/rootfs.tar.xz"
    echo "Jenkins-style example URL: $jenkins_url"
    printf "Checking example Jenkins URL...\n"
    if check_url "$jenkins_url"; then
      printf "Note: Jenkins example URL reachable (but GitHub asset missing).\n"
    else
      printf "Note: Jenkins example URL not reachable.\n"
      exit_code=4
    fi
    continue
  fi

  printf "Resolved download URL: %s\n" "$dl_url"
  if ! check_url "$dl_url"; then
    exit_code=5
  fi
done

if [[ $exit_code -ne 0 ]]; then
  echo "\nOne or more checks failed (exit $exit_code)." >&2
else
  echo "\nAll checks passed." 
fi

exit $exit_code
