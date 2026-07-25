#!/bin/zsh
# The deterministic debug loop. Debugging the app ALWAYS goes through this
# script and the debug build — never /Applications/Continuations.app,
# which is the shipped release carrying real prefs and state.
#
# One invocation = one fresh instance: rebuild dist/Continuation-Debug.app,
# replace any running debug instance, launch, and log to a fixed path.
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/bundle.sh --debug > /dev/null

# The debug app's home is /Applications (user ruling 2026-07-25): the
# walkthrough copy and the debugged copy are the same artifact.
APP=/Applications/Continuation-Debug.app
LOG=/tmp/continuation-debug.log

# Replace, never accumulate: the debug executable name is unique, so this
# cannot touch a running release app.
pkill -x Continuation-Debug 2>/dev/null || true
rm -rf "$APP"
ditto dist/Continuation-Debug.app "$APP"

: > "$LOG"
"$APP/Contents/MacOS/Continuation-Debug" >> "$LOG" 2>&1 &
PID=$!
echo "launched $APP (pid $PID)"
echo "log: $LOG"
