#!/usr/bin/env bash

# Shared transaction journal for privileged host scripts.
# Call safe_begin once, safe_checkpoint around irreversible boundaries, and
# safe_complete only after the intended state has been verified.

SAFE_TRANSACTION_ACTIVE=0
SAFE_TRANSACTION_DIR=""
SAFE_TRANSACTION_LOG=""
SAFE_TRANSACTION_STATUS=""

safe_begin() {
  local operation="$1"
  local root

  umask 077
  command -v flock >/dev/null 2>&1 || {
    printf 'ERROR: flock is required.\n' >&2
    return 127
  }

  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    root="${SAFE_STATE_ROOT:-/var/lib/useful-shell/transactions}"
  else
    root="${SAFE_STATE_ROOT:-${XDG_STATE_HOME:-$HOME/.local/state}/useful-shell/transactions}"
  fi
  install -d -m 0700 -- "$root"

  exec {SAFE_TRANSACTION_LOCK_FD}>"$root/$operation.lock"
  if ! flock -n "$SAFE_TRANSACTION_LOCK_FD"; then
    printf 'ERROR: another %s transaction is active.\n' "$operation" >&2
    return 75
  fi

  local transaction_id
  transaction_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
  SAFE_TRANSACTION_DIR="$root/$operation-$transaction_id"
  install -d -m 0700 -- "$SAFE_TRANSACTION_DIR"
  SAFE_TRANSACTION_LOG="$SAFE_TRANSACTION_DIR/events.log"
  SAFE_TRANSACTION_STATUS="$SAFE_TRANSACTION_DIR/status"
  : >"$SAFE_TRANSACTION_LOG"
  chmod 0600 "$SAFE_TRANSACTION_LOG"
  printf 'ACTIVE\n' >"$SAFE_TRANSACTION_STATUS"
  chmod 0600 "$SAFE_TRANSACTION_STATUS"
  SAFE_TRANSACTION_ACTIVE=1

  safe_event "begin" "$operation"
  safe_event "host" "$(hostname -f 2>/dev/null || hostname)"
  safe_event "pid" "$$"
  trap '_safe_transaction_error $? $LINENO' ERR
  trap '_safe_transaction_signal INT' INT
  trap '_safe_transaction_signal TERM' TERM
  printf 'Transaction: %s\n' "$SAFE_TRANSACTION_DIR"
}

safe_event() {
  local event="$1"
  local detail="${2:-}"
  [[ "$SAFE_TRANSACTION_ACTIVE" -eq 1 ]] || return 0
  detail="${detail//$'\n'/ }"
  printf '%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$event" "$detail" >>"$SAFE_TRANSACTION_LOG"
}

safe_checkpoint() {
  local name="$1"
  local recovery="${2:-See the script recovery documentation.}"
  printf '%s\n' "$name" >"$SAFE_TRANSACTION_DIR/checkpoint"
  printf '%s\n' "$recovery" >"$SAFE_TRANSACTION_DIR/recovery.txt"
  chmod 0600 "$SAFE_TRANSACTION_DIR/checkpoint" "$SAFE_TRANSACTION_DIR/recovery.txt"
  safe_event "checkpoint" "$name"
}

safe_snapshot_file() {
  local source="$1"
  local label="$2"
  local destination="$SAFE_TRANSACTION_DIR/$label"
  if [[ -e "$source" || -L "$source" ]]; then
    cp -a -- "$source" "$destination"
    safe_event "snapshot" "$label"
  else
    : >"$destination.absent"
    chmod 0600 "$destination.absent"
    safe_event "snapshot-absent" "$label"
  fi
}

safe_run() {
  local stage="$1"
  shift
  safe_event "stage-start" "$stage command=$(basename "$1")"
  if [[ "${USEFUL_SHELL_FAIL_STAGE:-}" == "$stage" ]]; then
    printf 'Injected failure at stage: %s\n' "$stage" >&2
    return 97
  fi
  "$@"
  safe_event "stage-complete" "$stage"
}

safe_complete() {
  safe_event "complete" "verified"
  printf 'COMPLETE\n' >"$SAFE_TRANSACTION_STATUS"
  SAFE_TRANSACTION_ACTIVE=0
  trap - ERR INT TERM
}

_safe_transaction_error() {
  local code="$1"
  local line="$2"
  trap - ERR
  if [[ "$SAFE_TRANSACTION_ACTIVE" -eq 1 ]]; then
    safe_event "failed" "exit=$code line=$line"
    printf 'RECOVERABLE\n' >"$SAFE_TRANSACTION_STATUS"
    printf 'ERROR: transaction stopped at a recoverable checkpoint: %s\n' "$SAFE_TRANSACTION_DIR" >&2
  fi
  exit "$code"
}

_safe_transaction_signal() {
  local signal="$1"
  safe_event "interrupted" "$signal"
  printf 'RECOVERABLE\n' >"$SAFE_TRANSACTION_STATUS"
  printf 'Interrupted. Recovery evidence: %s\n' "$SAFE_TRANSACTION_DIR" >&2
  trap - "$signal"
  kill -s "$signal" "$$"
}
