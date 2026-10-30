#!/bin/bash
# Controlled Arma 3 launch for log experiments: starts the native build exactly like Kitbag,
# samples the process's open files, then terminates it and keeps a copy of eon.txt.
# usage: launch.sh <label> <seconds> <mod folders joined by ;> [extra game args...]
set -u
LABEL=$1; SECS=$2; MODS=$3; shift 3
GAME="$HOME/Library/Application Support/Steam/steamapps/common/Arma 3"
EXE="$GAME/ArmA3 AS Native.app/Contents/MacOS/ArmA3 AS Native"
OUT="$(cd "$(dirname "$0")" && pwd)"
WRAP="$HOME/Library/Application Support/com.vpltd.Arma3"

touch "$OUT/.stamp-$LABEL"
echo "$MODS" | tr ';' '\n' > "$OUT/$LABEL.mods.txt"
cd "$GAME" || exit 1
"$EXE" -skipIntro -noSplash -world=empty "-mod=$MODS" "$@" > "$OUT/$LABEL.stdout.txt" 2>&1 &
PID=$!
echo "pid $PID started $(date)" > "$OUT/$LABEL.run.txt"

END=$((SECONDS + SECS))
while [ $SECONDS -lt $END ]; do
    sleep 15
    kill -0 $PID 2>/dev/null || { echo "process exited early at ${SECONDS}s" >> "$OUT/$LABEL.run.txt"; break; }
    { echo "--- t=$SECONDS"; lsof -p $PID 2>/dev/null | grep -i -E '\.rpt|\.log|\.txt|\.mdmp|crash' ; } >> "$OUT/$LABEL.lsof.txt"
done

pkill -f "ArmA3 AS Native.app/Contents/MacOS"
sleep 3
pkill -9 -f "ArmA3 AS Native.app/Contents/MacOS" 2>/dev/null
cp "$WRAP/eon.txt" "$OUT/$LABEL.eon.txt"
echo "finished $(date)" >> "$OUT/$LABEL.run.txt"
{ echo "--- files newer than stamp"; find "$WRAP" "$GAME" "$HOME/Library/Logs" "$HOME/Library/Application Support/Steam" -maxdepth 4 -newer "$OUT/.stamp-$LABEL" -type f 2>/dev/null | grep -v -E '/steamapps/workshop/content|\.pbo$' | head -80; } >> "$OUT/$LABEL.run.txt"
pgrep -fl ArmA3 >> "$OUT/$LABEL.run.txt" || echo "no game process remains" >> "$OUT/$LABEL.run.txt"
