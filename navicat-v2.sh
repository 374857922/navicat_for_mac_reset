#!/bin/bash
set -Eeuo pipefail
umask 077
APP="/Applications/Navicat Premium.app"
ROOT="$HOME/Library/Application Support/NavicatTrialV2"
PREF="$HOME/Library/Preferences/com.navicat.NavicatPremium.plist"
SUPPORT="$HOME/Library/Application Support/PremiumSoft CyberTech/Navicat CC/Navicat Premium"
MODE="inspect"; CONFIRM=""; ID=""
log(){ printf '%s %s\n' "$(date '+%F %T')" "$*"; [[ ! -d "$ROOT/logs" ]] || printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$ROOT/logs/run.log"; }
fail(){ log "ERROR: $*"; exit 1; }
init(){ mkdir -p "$ROOT/backups" "$ROOT/logs"; chmod 700 "$ROOT" "$ROOT/backups" "$ROOT/logs"; }
stopcheck(){ ! pgrep -x "Navicat Premium" >/dev/null || fail "Quit Navicat first"; }
help(){ echo "Usage: bash navicat-v2.sh inspect|dry-run|backup|backups|reset --confirm RESET|restore ID --confirm RESTORE"; }
[[ "$(uname -s)" == Darwin ]] || { echo "macOS only"; exit 1; }
if (( $# )); then MODE="$1"; shift; fi
if [[ "$MODE" == restore ]]; then (( $# )) || fail "Missing backup ID"; ID="$1"; shift; fi
if (( $# )); then [[ "$1" == --confirm && $# == 2 ]] || fail "Invalid options"; CONFIRM="$2"; fi
case "$MODE" in
help) help; exit 0 ;;
backups) [[ ! -d "$ROOT/backups" ]] || find "$ROOT/backups" -mindepth 1 -maxdepth 1 -type d; exit 0 ;;
restore)
  [[ "$CONFIRM" == RESTORE ]] || fail "Require --confirm RESTORE"
  [[ "$ID" =~ ^[0-9]{8}-[0-9]{6}-[0-9]+$ ]] || fail "Invalid ID"
  DIR="$ROOT/backups/$ID"
  [[ -d "$DIR" && ! -L "$DIR" && -f "$DIR/version" ]] || fail "Backup not found"
  stopcheck
  if [[ -f "$DIR/prefs.plist" && -e "$PREF" ]]; then
    cmp -s "$DIR/prefs.plist" "$PREF" || fail "Current plist differs; move aside before recovery"
  fi
  mkdir -p "$SUPPORT" "$(dirname "$PREF")"
  shopt -s nullglob
  for F in "$DIR"/hidden/.*; do
    [[ -f "$F" ]] || continue
    DEST="$SUPPORT/$(basename "$F")"
    if [[ -e "$DEST" ]]; then cmp -s "$F" "$DEST" || fail "Conflicting hidden file: $DEST"; fi
  done
  [[ ! -f "$DIR/prefs.plist" ]] || cp -p "$DIR/prefs.plist" "$PREF"
  for F in "$DIR"/hidden/.*; do [[ ! -f "$F" ]] || cp -p "$F" "$SUPPORT/"; done
  log "Restored $ID"; exit 0 ;;
inspect|dry-run|backup|reset) ;;
*) help; exit 2 ;;
esac
[[ "$MODE" != backup && "$MODE" != reset ]] || init
[[ -f "$APP/Contents/Info.plist" ]] || fail "App missing"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist") || fail "Version unavailable"
BUNDLE=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist") || fail "Bundle ID unavailable"
[[ "$BUNDLE" == com.navicat.NavicatPremium ]] || fail "Unexpected app bundle"
[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+){1,3}$ ]] || fail "Invalid version"
ELIGIBLE=0
if [[ "$VERSION" =~ ^16\. ]]; then ELIGIBLE=1; fi
if [[ "$VERSION" =~ ^17\.([0-9]+)\.([0-9]+) ]]; then
  MINOR=$((10#000 + 10#$(echo "$VERSION" | cut -d. -f2)))
  PATCH=$((10#000 + 10#$(echo "$VERSION" | cut -d. -f3)))
  if (( MINOR < 3 || (MINOR == 3 && PATCH < 7) )); then ELIGIBLE=1; fi
fi
KEYS=(); FILES=()
if [[ -f "$PREF" ]]; then
  plutil -lint "$PREF" >/dev/null || fail "Corrupt plist"
  while IFS= read -r LINE; do
    if [[ "$LINE" =~ ^[[:space:]]*([A-Z0-9]{32})[[:space:]]*= ]]; then KEYS+=("${BASH_REMATCH[1]}"); fi
  done < <(defaults read "$PREF" 2>/dev/null || true)
fi
if [[ -d "$SUPPORT" ]]; then
  shopt -s nullglob
  for F in "$SUPPORT"/.*; do
    if [[ -f "$F" && ! -L "$F" && "$F" =~ /\.[A-Z0-9]{32}$ ]]; then FILES+=("$F"); fi
  done
  shopt -u nullglob
fi
log "Version=$VERSION arch=$(uname -m) legacy-policy=$ELIGIBLE keys=${#KEYS[@]} files=${#FILES[@]}"
if [[ "$MODE" == inspect ]]; then exit 0; fi
if [[ "$MODE" == dry-run ]]; then
  log "Dry run only: no files changed; reset would be $([[ "$ELIGIBLE" == 1 ]] && echo eligible || echo blocked)"
  exit 0
fi
stopcheck
backup(){
  ID="$(date '+%Y%m%d-%H%M%S')-$$"
  DIR="$ROOT/backups/$ID"
  mkdir -m 700 "$DIR" "$DIR/hidden"
  [[ ! -f "$PREF" ]] || cp -p "$PREF" "$DIR/prefs.plist"
  for F in "${FILES[@]}"; do cp -p "$F" "$DIR/hidden/"; done
  printf '%s\n' "$VERSION" > "$DIR/version"
  log "Backup ID: $ID"
}
if [[ "$MODE" == backup ]]; then backup; exit 0; fi
[[ "$ELIGIBLE" == 1 ]] || fail "Reset unsupported for $VERSION (newer license storage unverified)"
[[ "$CONFIRM" == RESET ]] || fail "Require --confirm RESET"
(( ${#KEYS[@]} + ${#FILES[@]} > 0 )) || fail "No known legacy records"
backup
for KEY in "${KEYS[@]}"; do defaults delete "$PREF" "$KEY" >/dev/null || fail "Key delete failed; backup saved"; done
for F in "${FILES[@]}"; do rm "$F" || fail "File removal failed; backup saved"; done
log "Legacy reset completed; no guarantee of trial renewal"
