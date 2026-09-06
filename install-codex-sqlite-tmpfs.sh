#!/usr/bin/env bash
# Run once:
#   sudo bash install-codex-sqlite-tmpfs.sh

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/safe-transaction.sh
source "$SCRIPT_DIR/lib/safe-transaction.sh"

BASE="/dev/shm/codex-sqlite"
TMPFILES="/etc/tmpfiles.d/codex-sqlite-tmpfs.conf"
PROFILE="/etc/profile.d/90-codex-sqlite-tmpfs.sh"

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

info() {
  printf '%s\n' "$*"
}

[ "${EUID}" -eq 0 ] || fail "Run this script with sudo or as root."

command -v getent >/dev/null || fail "getent is required."
command -v runuser >/dev/null || fail "runuser is required."
command -v findmnt >/dev/null || fail "findmnt is required."
command -v systemd-tmpfiles >/dev/null || fail "systemd-tmpfiles is required."

findmnt -n -o FSTYPE --target /dev/shm 2>/dev/null | grep -qx "tmpfs" ||
  fail "/dev/shm is not mounted as tmpfs."

UID_MIN="$(
  awk '$1 == "UID_MIN" { print $2; exit }' /etc/login.defs 2>/dev/null || true
)"
[ -n "$UID_MIN" ] || fail "UID_MIN is not defined in /etc/login.defs."

[ ! -L "$BASE" ] || fail "$BASE is a symlink; refusing to use it."

safe_begin "codex-sqlite-tmpfs"
safe_checkpoint "preflight" "No managed files have changed; inspect the journal and rerun."
safe_snapshot_file "$TMPFILES" tmpfiles.before
safe_snapshot_file "$PROFILE" profile.before

safe_checkpoint "base-directory" "Verify /dev/shm/codex-sqlite ownership and mode before rerunning."
install -d -m 0755 -o root -g root -- "$BASE"

safe_checkpoint "tmpfiles-config" "Restore tmpfiles.before, or verify the generated tmpfiles entries before rerunning."
: > "$TMPFILES"
printf 'd %s 0755 root root -\n' "$BASE" >> "$TMPFILES"

safe_checkpoint "profile-config" "Restore profile.before, or verify the managed profile script before rerunning."
cat > "$PROFILE" <<'PROFILE_EOF'
# Managed by install-codex-sqlite-tmpfs.sh
# Fallback for Codex started from login shells.
if [ -n "${UID:-}" ]; then
  _codex_sqlite_home="/dev/shm/codex-sqlite/${UID}"

  if [ -d "$_codex_sqlite_home" ] && [ ! -L "$_codex_sqlite_home" ]; then
    export CODEX_SQLITE_HOME="$_codex_sqlite_home"
  fi

  unset _codex_sqlite_home
fi
PROFILE_EOF

chmod 0644 "$PROFILE"
chown root:root "$PROFILE"

configure_user() {
  local user="$1"
  local uid="$2"
  local gid="$3"
  local home="$4"
  local sqlite_dir="$BASE/$uid"

  safe_checkpoint "user-$uid" "Restore this user's timestamped config backup and verify its SQLite directory before rerunning."
  [ ! -L "$sqlite_dir" ] ||
    fail "$sqlite_dir is a symlink; refusing to use it."

  install -d -m 0700 -o "$uid" -g "$gid" -- "$sqlite_dir"
  chown "$uid:$gid" -- "$sqlite_dir"
  chmod 0700 -- "$sqlite_dir"

  printf 'd %s 0700 %s %s -\n' \
    "$sqlite_dir" "$uid" "$gid" >> "$TMPFILES"

  runuser -u "$user" -- \
    env HOME="$home" SQLITE_DIR="$sqlite_dir" bash <<'USER_EOF'
set -Eeuo pipefail
umask 077

codex_dir="$HOME/.codex"
mkdir -p -- "$codex_dir"

[ -d "$codex_dir" ] ||
  { printf 'ERROR: %s is not a directory\n' "$codex_dir" >&2; exit 1; }

cfg="$codex_dir/config.toml"

[ ! -L "$cfg" ] ||
  { printf 'ERROR: refusing symlinked config: %s\n' "$cfg" >&2; exit 1; }

touch -- "$cfg"

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
cp -p -- "$cfg" "$cfg.bak.$stamp"

tmp="$(mktemp "$codex_dir/.config.toml.XXXXXX")"
out="$(mktemp "$codex_dir/.config.toml.new.XXXXXX")"

trap 'rm -f -- "$tmp" "$out"' EXIT

awk '
  BEGIN { top_level = 1 }

  /^[[:space:]]*\[[^]]+\][[:space:]]*(#.*)?$/ {
    top_level = 0
  }

  top_level && /^[[:space:]]*sqlite_home[[:space:]]*=/ {
    next
  }

  {
    print
  }
' "$cfg" > "$tmp"

{
  printf '%s\n' '# Managed by install-codex-sqlite-tmpfs.sh'
  printf 'sqlite_home = "%s"\n\n' "$SQLITE_DIR"
  cat -- "$tmp"
} > "$out"

mv -f -- "$out" "$cfg"
USER_EOF

  info "Configured ${user}: ${sqlite_dir}"
}

while IFS=: read -r user _ uid gid _ home shell; do
  [ -n "$user" ] || continue
  [ -d "$home" ] || continue
  [ ! -L "$home" ] || continue
  [ "$(stat -c '%u' -- "$home")" = "$uid" ] || continue

  case "$shell" in
    */nologin|*/false|"") continue ;;
  esac

  if [ "$uid" -ne 0 ] && [ "$uid" -lt "$UID_MIN" ]; then
    continue
  fi

  configure_user "$user" "$uid" "$gid" "$home"
done < <(getent passwd)

chmod 0644 "$TMPFILES"
chown root:root "$TMPFILES"

safe_checkpoint "tmpfiles-apply" "Run systemd-tmpfiles --create after validating the generated configuration."
safe_run "tmpfiles-apply" systemd-tmpfiles --create "$TMPFILES"

safe_checkpoint "verify" "Validate managed files and per-user directories, then rerun if any entry is incomplete."
test -d "$BASE"
test -f "$TMPFILES"
test -f "$PROFILE"
safe_complete

info
info "Done."
info "Restart Codex in every account before testing."
info "Verify with:"
info "find /dev/shm/codex-sqlite -maxdepth 2 -type f -printf '%p %s bytes\n'"
