#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="BetterDualSub"
BUNDLE_ID="studio.bbit.betterdualsub"
XCODE_DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA_DIR="/tmp/BetterDualSub-derived"
APP_BUNDLE="$DERIVED_DATA_DIR/Build/Products/Debug/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"

pkill -x "$APP_NAME" >/dev/null 2>&1 || true
DEVELOPER_DIR="$XCODE_DEVELOPER_DIR" "$XCODE_DEVELOPER_DIR/usr/bin/xcodebuild" \
  -project "$PROJECT_ROOT/BetterDualSub.xcodeproj" \
  -scheme "$APP_NAME" \
  -configuration Debug \
  -derivedDataPath "$DERIVED_DATA_DIR" \
  CODE_SIGNING_ALLOWED=NO build

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
