#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE="$ROOT_DIR/QuickTime Player Plus.app"
APP_EXECUTABLE="$APP_BUNDLE/Contents/MacOS/QuickTime Player"
REAL_APP_EXECUTABLE="$APP_BUNDLE/Contents/MacOS/QuickTime Player.real"
INJECTOR="$ROOT_DIR/build/QuickTimePlayerPlus.dylib"
PLUGIN_DIR="$ROOT_DIR/build/PlugIns"

normalize_arg() {
  local value="$1"
  if [[ "$value" == "~" ]]; then
    value="$HOME"
  elif [[ "$value" == "~/"* ]]; then
    value="$HOME/${value:2}"
  fi

  if [[ -e "$value" ]]; then
    local dir
    dir="$(cd "$(dirname "$value")" && pwd)"
    printf '%s/%s\n' "$dir" "$(basename "$value")"
  else
    printf '%s\n' "$value"
  fi
}

if [[ -x "$REAL_APP_EXECUTABLE" ]]; then
  APP_EXECUTABLE="$REAL_APP_EXECUTABLE"
fi

if [[ ! -x "$APP_EXECUTABLE" ]]; then
  echo "QuickTime Player executable not found: $APP_EXECUTABLE" >&2
  exit 1
fi

cd "$ROOT_DIR"
make all

pkill -x "QuickTime Player" 2>/dev/null || true
pkill -x "QuickTime Player.real" 2>/dev/null || true

if [[ "${1:-}" == "--verify" ]]; then
  DYLD_INSERT_LIBRARIES="$INJECTOR" \
  QTP_PLUGIN_PATH="$PLUGIN_DIR" \
  "$APP_EXECUTABLE" &
  app_pid=$!
  sleep 2
  pgrep -x "QuickTime Player" >/dev/null
  echo "QuickTime Player launched with QuickTimePlayer+ injector (pid $app_pid)."
  exit 0
fi

args=()
for arg in "$@"; do
  args+=("$(normalize_arg "$arg")")
done

DYLD_INSERT_LIBRARIES="$INJECTOR" \
QTP_PLUGIN_PATH="$PLUGIN_DIR" \
"$APP_EXECUTABLE" "${args[@]}"
