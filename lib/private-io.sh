#!/usr/bin/env bash

private_io_init() {
  set +x
  umask 077
}

private_read_secret() {
  local destination="$1"
  local label="$2"
  local descriptor="${3:-}"
  local value=""

  if [[ -n "$descriptor" ]]; then
    [[ "$descriptor" =~ ^[0-9]+$ ]] || {
      printf 'ERROR: secret descriptor must be numeric.\n' >&2
      return 64
    }
    IFS= read -r -u "$descriptor" value || {
      printf 'ERROR: cannot read %s from descriptor %s.\n' "$label" "$descriptor" >&2
      return 65
    }
  elif [[ -t 0 ]]; then
    IFS= read -r -s -p "$label: " value
    printf '\n' >&2
  else
    printf 'ERROR: provide %s through a descriptor or interactive input.\n' "$label" >&2
    return 66
  fi

  [[ -n "$value" ]] || {
    printf 'ERROR: %s is empty.\n' "$label" >&2
    return 67
  }
  printf -v "$destination" '%s' "$value"
}

private_prepare_report() {
  local report="$1"
  local parent
  parent="$(dirname "$report")"
  install -d -m 0700 -- "$parent"
  : >"$report"
  chmod 0600 -- "$report"
}

private_temp_dir() {
  local destination="$1"
  local directory
  directory="$(mktemp -d "${TMPDIR:-/tmp}/useful-shell.XXXXXX")"
  chmod 0700 "$directory"
  printf -v "$destination" '%s' "$directory"
}
