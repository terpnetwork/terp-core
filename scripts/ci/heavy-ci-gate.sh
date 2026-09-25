#!/usr/bin/env bash
# Decide whether a heavy workflow may run.
# Push to dev/**, release/**, or *-dev, tags, and workflow_dispatch: yes.
# Pull requests: yes only after an APPROVED review from a login in CODEOWNERS.
# Prints proceed=true|false for GITHUB_OUTPUT. Does not fail the job when waiting.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
EVENT="${EVENT_NAME:-${GITHUB_EVENT_NAME:-}}"
OUT="${GITHUB_OUTPUT:-}"

proceed() {
  echo "proceed=$1"
  if [ -n "$OUT" ]; then
    echo "proceed=$1" >> "$OUT"
  fi
}

case "$EVENT" in
  push|workflow_dispatch|release)
    proceed true
    exit 0
    ;;
esac

base="${PR_BASE_REF:-}"
case "$base" in
  dev|dev/*|release|release/*|*-dev) ;;
  *)
    echo "heavy-ci: base '$base' is not dev/**, release/**, or *-dev"
    proceed false
    exit 0
    ;;
esac

if [ "$EVENT" = "pull_request_review" ] && [ "${REVIEW_STATE:-}" != "approved" ]; then
  echo "heavy-ci: review is ${REVIEW_STATE:-unset}, not approved"
  proceed false
  exit 0
fi

owners="$(
  awk '
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    {
      for (i = 1; i <= NF; i++) if ($i ~ /^@/) {
        u = substr($i, 2)
        sub(/\/.*$/, "", u)
        print tolower(u)
      }
    }
  ' "$ROOT/.github/CODEOWNERS" | sort -u
)"
if [ -z "$owners" ]; then
  echo "ERROR: no @logins in .github/CODEOWNERS" >&2
  exit 1
fi

if [ -z "${PR_NUMBER:-}" ]; then
  echo "heavy-ci: pull request number missing"
  proceed false
  exit 0
fi

repo="${GITHUB_REPOSITORY:?}"
reviews="$(gh api --paginate "repos/${repo}/pulls/${PR_NUMBER}/reviews" --jq '.[] | select(.state=="APPROVED") | .user.login')"
ok=0
while read -r login; do
  [ -n "$login" ] || continue
  if echo "$owners" | grep -qx "$(printf '%s' "$login" | tr '[:upper:]' '[:lower:]')"; then
    echo "heavy-ci: approved by code owner $login"
    ok=1
    break
  fi
done <<< "$reviews"

if [ "$ok" = "1" ]; then
  proceed true
else
  echo "::notice::Heavy CI waits for an APPROVED review from a CODEOWNER ($(echo "$owners" | paste -sd, -))"
  proceed false
fi
