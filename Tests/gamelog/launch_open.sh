#!/bin/bash
# Controlled Arma 3 launch through LaunchServices (the way Steam starts the game), for the Rosetta
# build, because direct exec of "ArmA3 AS Native" crashes at startup on macOS 27.
# Samples the process's open files, then terminates it and keeps a copy of eon.txt.
# usage: launch_open.sh <label> <seconds> <app name without .app> <mod folders joined by ;> [extra args...]
set -u
LABEL=$1; SECS=$2; APP=$3; MODS=$4; shift 4
GAME="$HOME/Library/Application Support/Steam/steamapps/common/Arma 3"
OUT="$(cd "$(dirname "$0")" && pwd)"
WRAP="$HOME/Library/Application Support/com.vpltd.Arma3"

touch "$OUT/.stamp-$LABEL"
echo "$MODS" | tr ';' '\n' > "$OUT/$LABEL.mods.txt"
cd "$GAME" || exit 1
open -n -a "$GAME/$APP.app" --stdout "$OUT/$LABEL.stdout.txt" --stderr "$OUT/$LABEL.stderr.txt" \
    --args -skipIntro -noSplash -world=empty "-mod=$MODS" "$@"
echo "open rc=$? at $(date)" > "$OUT/$LABEL.run.txt"

PID=""
for i in 1 2 3 4 5 6 7 8 9 10; do
    PID=$(pgrep -f "$APP.app/Contents/MacOS" | head -1)
    [ -n "$PID" ] && break
    sleep 1
done
echo "pid=$PID" >> "$OUT/$LABEL.run.txt"

END=$((SECONDS + SECS))
while [ $SECONDS -lt $END ]; do
    sleep 10
    kill -0 "$PID" 2>/dev/null || { echo "process exited early at ${SECONDS}s" >> "$OUT/$LABEL.run.txt"; break; }
    { echo "--- t=$SECONDS"; lsof -p "$PID" 2>/dev/null | awk 'NR>1 && $5=="REG"' | grep -v -E '\.pbo|\.dylib|/System/|/usr/lib|\.bisign|/Library/Frameworks|\.car$|\.icns' ; } >> "$OUT/$LABEL.lsof.txt"
    wc -l < "$WRAP/eon.txt" | sed "s/^/eon.txt lines at t=$SECONDS: /" >> "$OUT/$LABEL.run.txt"
done

pkill -f "ArmA3.*.app/Contents/MacOS"
sleep 3
pkill -9 -f "ArmA3.*.app/Contents/MacOS" 2>/dev/null
cp "$WRAP/eon.txt" "$OUT/$LABEL.eon.txt"
echo "finished $(date)" >> "$OUT/$LABEL.run.txt"
{ echo "--- files newer than stamp"; find "$WRAP" "$GAME" "$HOME/Library/Logs" "$HOME/Documents" -maxdepth 5 -newer "$OUT/.stamp-$LABEL" -type f 2>/dev/null | grep -v -E '/steamapps/workshop/content|\.pbo$' | head -80; } >> "$OUT/$LABEL.run.txt"
pgrep -fl ArmA3 >> "$OUT/$LABEL.run.txt" || echo "no game process remains" >> "$OUT/$LABEL.run.txt"
