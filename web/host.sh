#!/bin/bash
# Runs the website on this Mac at http://localhost:4300.
#   ./host.sh start      build and start (or restart) it
#   ./host.sh stop
#   ./host.sh status
cd "$(dirname "$0")"
PID_FILE="$HOME/Library/Application Support/StreamSetuSite/site.pid"
LOG_FILE="$HOME/Library/Application Support/StreamSetuSite/site.log"
mkdir -p "$(dirname "$PID_FILE")"

running() { [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; }

stop() {
  if running; then kill "$(cat "$PID_FILE")"; sleep 1; fi
  rm -f "$PID_FILE"
}

case "${1:-status}" in
  start|restart)
    stop
    export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
    [ -d node_modules ] || npm install
    npm run build >> "$LOG_FILE" 2>&1 || { echo "The build failed. See $LOG_FILE"; exit 1; }
    nohup npm run start >> "$LOG_FILE" 2>&1 &
    echo $! > "$PID_FILE"
    sleep 2
    echo "Running at http://localhost:4300"
    ;;
  stop) stop; echo "Stopped" ;;
  status) if running; then echo "Running at http://localhost:4300"; else echo "Not running"; fi ;;
  *) echo "Use start, stop or status"; exit 1 ;;
esac
