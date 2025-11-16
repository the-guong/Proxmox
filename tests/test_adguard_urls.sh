#!/usr/bin/env bash
set -euo pipefail

# Test script for ct/adguard.sh
# - extracts all http(s) URLs from the script
# - attempts DNS resolution for each hostname
# - attempts to download each URL (small GET) to ensure it's reachable
# Usage: tests/test_adguard_urls.sh [path-to-config-file]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# adguard installer lives under ct/, tests/ is at repo root so reference ../ct/adguard.sh
SCRIPT_FILE="$SCRIPT_DIR/../ct/adguard.sh"
CONFIG_FILE="${1:-}"

if [[ ! -f "$SCRIPT_FILE" ]]; then
  echo "ERROR: $SCRIPT_FILE not found"
  exit 2
fi

verbose() { [[ ${VERBOSE:-yes} == yes ]] && echo "$@"; }

resolve_host() {
  local host="$1"
  # Try getent
  if getent hosts "$host" >/dev/null 2>&1; then
    getent hosts "$host" | awk '{print $1; exit}'
    return 0
  fi
  # Try host
  if command -v host >/dev/null 2>&1; then
    host -t A "$host" 2>/dev/null | awk '/has address/ {print $4; exit}' && return 0
  fi
  # Try dig
  if command -v dig >/dev/null 2>&1; then
    dig +short A "$host" | grep -Eo '^[0-9.]+' | head -n1 && return 0
  fi
  # Try nslookup
  if command -v nslookup >/dev/null 2>&1; then
    nslookup "$host" 2>/dev/null | awk '/^Address: /{print $2; exit}' && return 0
  fi
  # Try ping as last resort
  if ping -c1 -W1 "$host" >/dev/null 2>&1; then
    ping -c1 -W1 "$host" 2>/dev/null | head -n1
    return 0
  fi
  return 1
}

check_url() {
  local url="$1"
  local host
  host=$(echo "$url" | awk -F/ '{print $3}' | sed 's/:.*$//')
  printf "\nURL: %s\nHost: %s\n" "$url" "$host"

  if ip_addr=$(resolve_host "$host"); then
    echo "Resolve: OK -> $ip_addr"
  else
    echo "Resolve: FAIL"
    RESOLVE_FAILS=$((RESOLVE_FAILS+1))
  fi

  # Test download (follow redirects, time out quickly)
  if curl -fL --max-time 20 -sS -o /dev/null "$url"; then
    echo "Download: OK"
  else
    echo "Download: FAIL"
    DOWNLOAD_FAILS=$((DOWNLOAD_FAILS+1))
  fi
}

# If a config file provided, source it to expand e.g. ${IP} in printed URLs
if [[ -n "$CONFIG_FILE" ]]; then
  if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
    verbose "Sourced config: $CONFIG_FILE"
  else
    echo "WARN: config file '$CONFIG_FILE' not found, continuing without it"
  fi
fi

VERBOSE=${VERBOSE:-yes}
RESOLVE_FAILS=0
DOWNLOAD_FAILS=0

# Collect URLs from the script
mapfile -t URLS < <(grep -oE "https?://[^\"'<>[:space:]]+" "$SCRIPT_FILE" | sed -E 's/[[:space:]\)\]>;,\"]+$//' | sort -u)

# Also try to capture the 'Access it using the following URL' printed URL block
if grep -q "Access it using the following URL" "$SCRIPT_FILE" 2>/dev/null; then
  # extract the following line that contains http:// or https:// maybe with placeholders like ${IP}
  add=$(grep -A1 "Access it using the following URL" "$SCRIPT_FILE" | tail -n1 | sed -n 's/.*\(http[^[:space:]]*\).*/\1/p' || true)
  if [[ -n "$add" ]]; then
    # If config provided and envsubst available, expand placeholders safely
    if [[ -n "$CONFIG_FILE" && -f "$CONFIG_FILE" ]] && command -v envsubst >/dev/null 2>&1; then
      # ensure config variables are in environment
      # shellcheck disable=SC1090
      source "$CONFIG_FILE"
      expanded=$(printf '%s' "$add" | envsubst)
      URLS+=("$expanded")
    else
      # otherwise remove any ${...} placeholders and trailing garbage
      cleaned=$(printf '%s' "$add" | sed -E 's/\$\{[^}]*\}//g' | sed -E 's/[^A-Za-z0-9\/\._@:%?=&+#-]*$//')
      URLS+=("$cleaned")
    fi
  fi
fi

if [[ ${#URLS[@]} -eq 0 ]]; then
  echo "No URLs found in $SCRIPT_FILE"
  exit 0
fi

echo "Found ${#URLS[@]} unique URL(s) to check:" 
for u in "${URLS[@]}"; do echo " - $u"; done

for url in "${URLS[@]}"; do
  # If contains placeholders like ${IP}, try to expand with envsubst if available and a config is provided
  if [[ "$url" == *'${'* ]]; then
    if [[ -n "$CONFIG_FILE" && -f "$CONFIG_FILE" ]] && command -v envsubst >/dev/null 2>&1; then
      # shellcheck disable=SC1090
      source "$CONFIG_FILE"
      url=$(printf '%s' "$url" | envsubst)
    else
      # remove unexpanded placeholders
      url=$(printf '%s' "$url" | sed -E 's/\$\{[^}]*\}//g')
    fi
  fi

  # strip trailing garbage not part of a URL
  url=$(printf '%s' "$url" | sed -E 's/[^A-Za-z0-9\/\._@:%?=&+#-]*$//')

  # skip obviously invalid URLs (no host) - require host to start with alnum or dot/underscore/hyphen
  if ! printf '%s' "$url" | grep -qE '^https?://[A-Za-z0-9._-]+'; then
    echo "Skipping invalid URL: $url"
    continue
  fi

  check_url "$url" || true
done

echo "\nSummary:"
echo "DNS resolve failures: $RESOLVE_FAILS"
echo "Download failures:    $DOWNLOAD_FAILS"

if [[ $RESOLVE_FAILS -gt 0 || $DOWNLOAD_FAILS -gt 0 ]]; then
  echo "One or more checks failed"
  exit 3
fi

echo "All checks passed"
exit 0
