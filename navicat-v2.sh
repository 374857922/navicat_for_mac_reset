#!/bin/bash
# Navicat Trial V2.1: fail-closed local state maintenance, macOS Bash 3.2 compatible.
set -Eeo pipefail
umask 077

MODE="${1:-inspect}"
if (( $# )); then shift; fi
CONFIRM=""; ID=""; CONFLICT_POLICY="abort"; ALLOW_LEGACY=0
TEST_ROOT="${NAVICAT_V2_TEST_ROOT:-}"
TEST_MODE=0
if [[ -n "$TEST_ROOT" ]]; then
  [[ "${NAVICAT_V2_TEST_MODE:-}" == "1" && "$TEST_ROOT" == /* && -d "$TEST_ROOT" && ! -L "$TEST_ROOT" ]] || { echo "Invalid isolated test mode" >&2; exit 2; }
  TEST_MODE=1
  APP="$TEST_ROOT/app"
  ROOT="$TEST_ROOT/state"
  PREF="$TEST_ROOT/home/prefs.plist"
  SUPPORT="$TEST_ROOT/home/support"
else
  APP="/Applications/Navicat Premium.app"
  ROOT="$HOME/Library/Application Support/NavicatTrialV2"
  PREF="$HOME/Library/Preferences/com.navicat.NavicatPremium.plist"
  SUPPORT="$HOME/Library/Application Support/PremiumSoft CyberTech/Navicat CC/Navicat Premium"
fi
BACKUPS="$ROOT/backups"; LOGS="$ROOT/logs"; RECOVERY="$ROOT/recovery"
LOG_WRITE=0; VERSION=""; BUNDLE=""; ELIGIBLE=0
KEYS=(); FILES=(); RESTORE_RELS=(); RESTORE_SRCS=(); RESTORE_DESTS=()
TXN=""; TXN_ACTIVE=0; TXN_COMPLETED=0; TXN_APPLIED=0

usage() {
cat <<'HELP'
Navicat macOS V2.1
  bash navicat-v2.sh inspect
  bash navicat-v2.sh doctor
  bash navicat-v2.sh dry-run
  bash navicat-v2.sh backup
  bash navicat-v2.sh backups
  bash navicat-v2.sh verify-backup ID
  bash navicat-v2.sh restore ID --confirm RESTORE [--on-conflict archive] [--allow-legacy-backup]
  bash navicat-v2.sh reset --confirm RESET

No Keychain entries are read, deleted or restored. Reset is blocked for
Navicat 17.3.7+ and 18.x until compatibility is independently validated.

V2.0 backup archives have no SHA-256 manifest. To restore one, explicitly
opt in with --allow-legacy-backup after reviewing the backup source.
HELP
}
log() {
  local entry
  entry="$(date '+%Y-%m-%d %H:%M:%S') $*"
  printf '%s\n' "$entry"
  if [[ "$LOG_WRITE" == 1 ]]; then
    printf '%s\n' "$entry" >> "$LOGS/run.log"
  fi
}
fail() { log "ERROR: $*"; exit 1; }
initialize() {
  [[ ! -L "$ROOT" ]] || fail "State directory must not be a symlink"
  mkdir -p "$BACKUPS" "$LOGS" "$RECOVERY"
  chmod 700 "$ROOT" "$BACKUPS" "$LOGS" "$RECOVERY"
  LOG_WRITE=1
}
check_os() {
  if [[ "$TEST_MODE" != 1 ]]; then
    [[ "$(uname -s)" == Darwin ]] || fail "macOS only"
  fi
}
check_stopped() {
  if [[ "$TEST_MODE" == 1 ]]; then
    [[ ! -e "$TEST_ROOT/running" ]] || fail "Navicat is running"
  else
    ! pgrep -x 'Navicat Premium' >/dev/null 2>&1 || fail "Quit Navicat Premium first"
  fi
}
detect() {
  if [[ "$TEST_MODE" == 1 ]]; then
    [[ -f "$APP/version" && -f "$APP/bundle" ]] || fail "Fixture app metadata missing"
    VERSION=$(cat "$APP/version")
    BUNDLE=$(cat "$APP/bundle")
  else
    [[ -f "$APP/Contents/Info.plist" ]] || fail "Navicat Premium app not found"
    VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist") || fail "Unable to read app version"
    BUNDLE=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist") || fail "Unable to read bundle ID"
  fi
  [[ "$VERSION" =~ ^[0-9]+(\.[0-9]+){1,3}$ ]] || fail "Malformed app version"
  [[ "$BUNDLE" == 'com.navicat.NavicatPremium' ]] || fail "Unexpected bundle ID: $BUNDLE"
  ELIGIBLE=0
  if [[ "$VERSION" =~ ^16\. ]]; then
    ELIGIBLE=1
  elif [[ "$VERSION" =~ ^17\.([0-9]+)\.([0-9]+) ]]; then
    local minor patch
    minor=$((10#${BASH_REMATCH[1]}))
    patch=$((10#${BASH_REMATCH[2]}))
    if (( minor < 3 || (minor == 3 && patch < 7) )); then ELIGIBLE=1; fi
  fi
  log "App: version=$VERSION bundle=$BUNDLE architecture=$(uname -m)"
}
validate_plist() {
  local file="$1"
  [[ -f "$file" && ! -L "$file" ]] || fail "Expected regular plist: $file"
  if [[ "$TEST_MODE" == 1 ]]; then
    ! grep -q '^CORRUPT_PLIST$' "$file" || fail "Fixture plist is invalid"
  else
    plutil -lint "$file" >/dev/null || fail "Invalid plist: $file"
  fi
}
read_plist() {
  if [[ "$TEST_MODE" == 1 ]]; then
    cat "$PREF"
  else
    defaults read "$PREF"
  fi
}
delete_plist_key() {
  local key="$1"
  if [[ "$TEST_MODE" == 1 ]]; then
    local tmp="$PREF.v21-tmp-$$"
    grep -v -E "^[[:space:]]*$key[[:space:]]*=" "$PREF" > "$tmp" || [[ "$?" == 1 ]]
    mv -f "$tmp" "$PREF"
  else
    defaults delete "$PREF" "$key" >/dev/null
  fi
}
scan() {
  KEYS=(); FILES=()
  local line f raw
  if [[ -e "$PREF" || -L "$PREF" ]]; then
    validate_plist "$PREF"
    raw=$(read_plist) || fail "Unable to read preferences"
    while IFS= read -r line; do
      if [[ "$line" =~ ^[[:space:]]*([A-Z0-9]{32})[[:space:]]*= ]]; then
        KEYS+=("${BASH_REMATCH[1]}")
      fi
    done <<< "$raw"
  fi
  if [[ -d "$SUPPORT" ]]; then
    shopt -s nullglob
    for f in "$SUPPORT"/.*; do
      [[ -f "$f" && ! -L "$f" ]] || continue
      if [[ "${f##*/}" =~ ^\.[A-Z0-9]{32}$ ]]; then FILES+=("$f"); fi
    done
    shopt -u nullglob
  fi
  log "Local records: matching_keys=${#KEYS[@]} matching_hidden_files=${#FILES[@]}"
  if [[ "$ELIGIBLE" == 1 ]]; then log "Legacy reset policy: eligible (not a trial guarantee)"; else log "Legacy reset policy: BLOCKED for $VERSION"; fi
}
hash_file() {
  local result
  result=$(shasum -a 256 "$1") || return 1
  printf '%s\n' "${result%% *}"
}
# Only these fixed relative paths are allowed inside a snapshot.
valid_relative() {
  [[ "$1" == version || "$1" == prefs.plist || "$1" =~ ^hidden/\.[A-Z0-9]{32}$ ]]
}
manifest_line() {
  local dir="$1" rel="$2" sha
  sha=$(hash_file "$dir/$rel") || return 1
  printf '%s  %s\n' "$sha" "$rel" >> "$dir/manifest.sha256"
}
backup_now() {
  local id tmp final f
  id="$(date '+%Y%m%d-%H%M%S')-$$"
  tmp="$BACKUPS/.pending-$id"; final="$BACKUPS/$id"
  [[ ! -e "$tmp" && ! -e "$final" ]] || fail "Backup ID collision"
  mkdir -m 700 "$tmp" "$tmp/hidden"
  printf '%s\n' "$VERSION" > "$tmp/version"
  if [[ -f "$PREF" ]]; then
    cp -p "$PREF" "$tmp/prefs.plist" || fail "Could not copy preferences"
    chmod 600 "$tmp/prefs.plist"
  fi
  for f in "${FILES[@]}"; do
    cp -p "$f" "$tmp/hidden/" || fail "Could not copy hidden file"
    chmod 600 "$tmp/hidden/${f##*/}"
  done
  : > "$tmp/manifest.sha256"
  manifest_line "$tmp" version || fail "Unable to hash version metadata"
  if [[ -f "$tmp/prefs.plist" ]]; then manifest_line "$tmp" prefs.plist || fail "Unable to hash preferences"; fi
  for f in "${FILES[@]}"; do manifest_line "$tmp" "hidden/${f##*/}" || fail "Unable to hash hidden file"; done
  chmod 600 "$tmp/version" "$tmp/manifest.sha256"
  verify_manifest "$tmp" || fail "New backup failed integrity verification"
  mv "$tmp" "$final"
  log "Backup complete: id=$id files=$(wc -l < "$final/manifest.sha256" | tr -d ' ')"
  ID="$id"
}
# No executable manifests, no traversal, no untracked snapshot files.
verify_manifest() {
  local dir="$1" sha rel actual total=0 counted=0 seen="|"
  [[ -f "$dir/manifest.sha256" && ! -L "$dir/manifest.sha256" ]] || return 1
  [[ -f "$dir/version" && ! -L "$dir/version" ]] || return 1
  while IFS=' ' read -r sha rel; do
    [[ "$sha" =~ ^[a-fA-F0-9]{64}$ ]] || return 1
    valid_relative "$rel" || return 1
    case "$seen" in *"|$rel|"*) return 1 ;; esac
    seen="$seen$rel|"
    [[ -f "$dir/$rel" && ! -L "$dir/$rel" ]] || return 1
    actual=$(hash_file "$dir/$rel") || return 1
    [[ "$actual" == "$sha" ]] || return 1
    total=$((total+1))
  done < "$dir/manifest.sha256"
  (( total > 0 )) || return 1
  # The file inventory must be exact (manifest plus checksummed files).
  counted=$(find "$dir" -type f | wc -l | tr -d ' ')
  (( counted == total + 1 )) || return 1
  [[ -z "$(find "$dir" -type l -print -quit)" ]] || return 1
  grep -Eq '^[a-fA-F0-9]{64}  version$' "$dir/manifest.sha256" || return 1
  return 0
}
backup_dir() {
  [[ "$ID" =~ ^[0-9]{8}-[0-9]{6}-[0-9]+$ ]] || fail "Invalid backup ID"
  local dir="$BACKUPS/$ID"
  [[ -d "$dir" && ! -L "$dir" && -f "$dir/version" && ! -L "$dir/version" ]] || fail "Backup not found"
  printf '%s\n' "$dir"
}
verify_backup() {
  local dir="$1"
  if [[ -f "$dir/manifest.sha256" ]]; then
    verify_manifest "$dir" || fail "Backup checksum or inventory mismatch"
    log "Backup verified: SHA-256 manifest OK"
  else
    [[ "$ALLOW_LEGACY" == 1 ]] || fail "V2.0 backup has no SHA-256 manifest; pass --allow-legacy-backup to opt in"
    [[ -f "$dir/version" && ! -L "$dir/version" ]] || fail "Missing legacy version metadata"
    if [[ -f "$dir/prefs.plist" ]]; then validate_plist "$dir/prefs.plist"; fi
    local f
    shopt -s nullglob
    for f in "$dir"/hidden/.*; do
      [[ "$f" == "$dir/hidden/." || "$f" == "$dir/hidden/.." ]] && continue
      [[ -f "$f" && ! -L "$f" ]] || fail "Unsafe legacy snapshot file"
      [[ "${f##*/}" =~ ^\.[A-Z0-9]{32}$ ]] || fail "Invalid legacy hidden filename"
    done
    shopt -u nullglob
    log "WARNING: legacy backup has no checksums (opt-in accepted)"
  fi
}
# Use the backup's saved inventory, not the live system's current scan.
prepare_restore() {
  local dir="$1" f name
  RESTORE_RELS=(); RESTORE_SRCS=(); RESTORE_DESTS=()
  if [[ -f "$dir/prefs.plist" ]]; then
    validate_plist "$dir/prefs.plist"
    RESTORE_RELS+=("prefs.plist"); RESTORE_SRCS+=("$dir/prefs.plist"); RESTORE_DESTS+=("$PREF")
  fi
  shopt -s nullglob
  for f in "$dir"/hidden/.*; do
    [[ "$f" == "$dir/hidden/." || "$f" == "$dir/hidden/.." ]] && continue
    [[ -f "$f" && ! -L "$f" ]] || fail "Unsafe snapshot file"
    name="${f##*/}"
    [[ "$name" =~ ^\.[A-Z0-9]{32}$ ]] || fail "Unsafe hidden filename"
    RESTORE_RELS+=("hidden/$name"); RESTORE_SRCS+=("$f"); RESTORE_DESTS+=("$SUPPORT/$name")
  done
  shopt -u nullglob
}
# Trap-assisted rollback for caught failures. SIGKILL/power loss cannot be trapped;
# recovery journal is preserved for manual inspection.
abort_restore() {
  local status="$1" i dest rel old
  trap - ERR INT TERM
  if [[ "$TXN_ACTIVE" == 1 && "$TXN_COMPLETED" != 1 ]]; then
    set +e
    log "Restore interrupted; attempting rollback from $TXN"
    for (( i=0; i<TXN_APPLIED; i++ )); do
      dest="${RESTORE_DESTS[$i]}"; rel="${RESTORE_RELS[$i]}"; old="$TXN/original/$rel"
      if [[ -f "$old" ]]; then
        cp -p "$old" "$dest.v21-rollback-$$" && mv -f "$dest.v21-rollback-$$" "$dest"
      else
        rm -f "$dest"
      fi
    done
    printf 'ROLLED_BACK_ATTEMPTED\n' > "$TXN/status"
    set -e
  fi
  exit "$status"
}
restore_now() {
  [[ "$CONFIRM" == RESTORE ]] || fail "Restore requires --confirm RESTORE"
  local dir saved_version i rel src dest conflicts=0 now journal parent staged
  dir=$(backup_dir)
  verify_backup "$dir"
  saved_version=$(cat "$dir/version")
  detect
  [[ "$saved_version" == "$VERSION" ]] || fail "Backup version $saved_version differs from installed $VERSION"
  check_stopped
  prepare_restore "$dir"
  for (( i=0; i<${#RESTORE_RELS[@]}; i++ )); do
    dest="${RESTORE_DESTS[$i]}"; src="${RESTORE_SRCS[$i]}"
    [[ ! -L "$dest" && ( ! -e "$dest" || -f "$dest" ) ]] || fail "Destination must be a regular file, not symlink"
    if [[ -f "$dest" ]] && ! cmp -s "$src" "$dest"; then conflicts=$((conflicts+1)); fi
  done
  if (( conflicts > 0 )) && [[ "$CONFLICT_POLICY" != archive ]]; then
    fail "$conflicts changed destination file(s); refusing overwrite. Use --on-conflict archive to preserve originals"
  fi
  TXN="$RECOVERY/$(date '+%Y%m%d-%H%M%S')-$$"
  mkdir -m 700 "$TXN" "$TXN/original"
  printf 'PREPARED\n' > "$TXN/status"
  for (( i=0; i<${#RESTORE_RELS[@]}; i++ )); do
    rel="${RESTORE_RELS[$i]}"; dest="${RESTORE_DESTS[$i]}"
    mkdir -p "$TXN/original/$(dirname "$rel")"
    if [[ -f "$dest" ]]; then cp -p "$dest" "$TXN/original/$rel"; chmod 600 "$TXN/original/$rel"; fi
  done
  TXN_ACTIVE=1
  trap 'abort_restore 1' ERR
  trap 'abort_restore 130' INT
  trap 'abort_restore 143' TERM
  printf 'APPLYING\n' > "$TXN/status"
  for (( i=0; i<${#RESTORE_RELS[@]}; i++ )); do
    src="${RESTORE_SRCS[$i]}"; dest="${RESTORE_DESTS[$i]}"
    parent="$(dirname "$dest")"
    mkdir -p "$parent"
    staged="$dest.v21-restore-$$"
    cp -p "$src" "$staged"
    mv -f "$staged" "$dest"
    TXN_APPLIED=$((TXN_APPLIED + 1))
    # Deterministic error injection only in isolated tests, after a write.
    if [[ "$TEST_MODE" == 1 && "${NAVICAT_V2_TEST_FAIL_AFTER_WRITE:-}" == "$((i+1))" ]]; then
      false
    fi
  done
  printf 'COMMITTED\n' > "$TXN/status"
  TXN_COMPLETED=1; TXN_ACTIVE=0
  trap - ERR INT TERM
  log "Restored id=$ID entries=${#RESTORE_RELS[@]} conflicts_archived=$conflicts journal=$TXN"
}
doctor() {
  local d ok=0 bad=0 legacy=0
  log "State directory: $([[ -d "$ROOT" ]] && echo present || echo absent)"
  if [[ -d "$BACKUPS" ]]; then
    shopt -s nullglob
    for d in "$BACKUPS"/[0-9]*; do
      [[ -d "$d" ]] || continue
      if [[ -f "$d/manifest.sha256" ]]; then
        if verify_manifest "$d"; then ok=$((ok+1)); else bad=$((bad+1)); fi
      else
        legacy=$((legacy+1))
      fi
    done
    shopt -u nullglob
  fi
  log "Backup health: verified=$ok corrupted=$bad legacy_unverified=$legacy"
  if [[ -d "$RECOVERY" ]]; then
    local pending=0
    shopt -s nullglob
    for d in "$RECOVERY"/*; do
      if [[ -d "$d" ]] && [[ ! -f "$d/status" || "$(cat "$d/status")" != COMMITTED ]]; then pending=$((pending+1)); fi
    done
    shopt -u nullglob
    log "Recovery journals needing review: $pending"
  fi
  (( bad == 0 )) || return 1
}

# CLI parsing deliberately rejects unknown or repeated options.
case "$MODE" in
  help|-h|--help) usage; exit 0 ;;
  inspect|doctor|dry-run|backup|backups|verify-backup|restore|reset) ;;
  *) usage; exit 2 ;;
esac
if [[ "$MODE" == restore || "$MODE" == verify-backup ]]; then
  (( $# > 0 )) || fail "Missing backup ID"
  ID="$1"; shift
fi
while (( $# )); do
  case "$1" in
    --confirm) (( $# >= 2 )) || fail "Missing confirmation value"; [[ -z "$CONFIRM" ]] || fail "Repeated confirmation"; CONFIRM="$2"; shift 2 ;;
    --on-conflict) (( $# >= 2 )) || fail "Missing conflict policy"; CONFLICT_POLICY="$2"; shift 2 ;;
    --allow-legacy-backup) ALLOW_LEGACY=1; shift ;;
    *) fail "Unknown argument: $1" ;;
  esac
done
[[ "$CONFLICT_POLICY" == abort || "$CONFLICT_POLICY" == archive ]] || fail "Invalid conflict policy"
if [[ "$MODE" != restore && "$CONFLICT_POLICY" != abort ]]; then fail "Conflict policy applies only to restore"; fi
if [[ "$MODE" != restore && "$MODE" != reset && -n "$CONFIRM" ]]; then fail "Confirmation applies only to restore/reset"; fi
if [[ "$MODE" != restore && "$MODE" != verify-backup && "$ALLOW_LEGACY" == 1 ]]; then fail "Legacy flag applies only to restore/verify-backup"; fi
check_os
case "$MODE" in
  backups)
    if [[ -d "$BACKUPS" ]]; then
      shopt -s nullglob
      for d in "$BACKUPS"/[0-9]*; do [[ ! -d "$d" ]] || printf '%s\n' "${d##*/}"; done
      shopt -u nullglob
    fi
    ;;
  verify-backup)
    dir=$(backup_dir)
    verify_backup "$dir"
    ;;
  restore)
    initialize
    restore_now
    ;;
  inspect|doctor|dry-run)
    detect
    scan
    if [[ "$MODE" == doctor ]]; then doctor; fi
    if [[ "$MODE" == dry-run ]]; then log "DRY RUN: no modifications; reset policy=$( [[ "$ELIGIBLE" == 1 ]] && echo eligible || echo blocked )"; fi
    ;;
  backup|reset)
    initialize
    detect
    scan
    check_stopped
    if [[ "$MODE" == backup ]]; then
      backup_now
    else
      [[ "$ELIGIBLE" == 1 ]] || fail "Reset blocked for unverified version $VERSION"
      [[ "$CONFIRM" == RESET ]] || fail "Reset requires --confirm RESET"
      (( ${#KEYS[@]} + ${#FILES[@]} > 0 )) || fail "No matching legacy records"
      backup_now
      for key in "${KEYS[@]}"; do delete_plist_key "$key" || fail "Key removal failed; backup=$ID"; done
      for f in "${FILES[@]}"; do rm -f "$f" || fail "File removal failed; backup=$ID"; done
      log "Legacy reset finished; new trial eligibility is NOT guaranteed; backup=$ID"
    fi
    ;;
esac
