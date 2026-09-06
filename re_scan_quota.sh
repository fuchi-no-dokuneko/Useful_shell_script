#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/safe-transaction.sh
source "$SCRIPT_DIR/lib/safe-transaction.sh"

HOST="$(hostname -f 2>/dev/null || hostname)"
QUOTA_DISABLED=0

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing command: $1" >&2
    exit 127
  }
}

snapshot() {
  local label="$1"

  echo
  echo "=============================="
  echo "$label"
  echo "date: $(date -Is)"
  echo "host: $HOST"
  echo "=============================="

  echo
  echo "===== quota state: quotaon -avugp ====="
  quotaon -avugp 2>&1 || true

  echo
  echo "===== user quota usage: repquota -avu ====="
  repquota -avu 2>&1 || true

  echo
  echo "===== group quota usage: repquota -avg ====="
  repquota -avg 2>&1 || true

  echo
}

run() {
  echo
  echo "+ $*"
  "$@"
}

on_error() {
  local rc="$?"

  echo
  echo "ERROR: command failed with exit code $rc" >&2

  if [[ "$QUOTA_DISABLED" -eq 1 ]]; then
    echo "Attempting to re-enable quotas: quotaon -avug" >&2
    quotaon -avug || true
  fi

  safe_abort "quota rescan failed with exit $rc"

  exit "$rc"
}

trap on_error ERR

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "Run as root, for example: sudo bash $0" >&2
  exit 1
fi

need_cmd quotaoff
need_cmd quotacheck
need_cmd quotaon
need_cmd repquota

cat <<EOF
Host: $HOST

No temporary files will be created.
No log files will be created.
No report files will be created.

Commands to run:
  quotaoff -avug
  quotacheck -avugm
  quotaon -avug
EOF

read -r -p "First confirmation: type QUOTA-CHECK to continue: " CONFIRM1
[[ "$CONFIRM1" == "QUOTA-CHECK" ]] || {
  echo "Aborted."
  exit 2
}

read -r -p "Second confirmation: type this hostname exactly [$HOST]: " CONFIRM2
[[ "$CONFIRM2" == "$HOST" ]] || {
  echo "Aborted."
  exit 3
}

safe_begin "quota-rescan"
trap on_error ERR
safe_checkpoint "preflight" "No quota state has changed; inspect the private preflight evidence and rerun."
safe_snapshot_file /etc/fstab fstab.before
snapshot "BEFORE quota and usage" | tee "$SAFE_TRANSACTION_DIR/quota-before.txt"
chmod 0600 "$SAFE_TRANSACTION_DIR/quota-before.txt"

safe_checkpoint "quota-off" "Run quotaon -avug if quotas are disabled, then inspect the journal."
safe_run "quota-off" quotaoff -avug
QUOTA_DISABLED=1

safe_checkpoint "quota-check" "Run quotaon -avug, validate quota files, then rerun the complete rescan."
safe_run "quota-check" quotacheck -avugm

safe_checkpoint "quota-on" "Verify quotaon -avugp and repair any filesystem still reporting quotas off."
safe_run "quota-on" quotaon -avug
QUOTA_DISABLED=0

safe_checkpoint "verify" "Compare quota-before.txt with the current quota state before rerunning."
snapshot "AFTER quota and usage" | tee "$SAFE_TRANSACTION_DIR/quota-after.txt"
chmod 0600 "$SAFE_TRANSACTION_DIR/quota-after.txt"
safe_complete

echo
echo "Done."
