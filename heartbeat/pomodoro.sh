#!/bin/bash
# pomodoro.sh — Autonomous work session
# Runs on a schedule via launchd/cron. Reviews intent queue, executes approved
# actions, does self-initiated work.

set -uo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_DIR="$PROJECT_DIR/logs"
LOG_FILE="$LOG_DIR/pomodoro.log"
PROMPT_FILE="$PROJECT_DIR/heartbeat/pomodoro-prompt.md"

timestamp() {
  date '+%Y-%m-%d %H:%M:%S'
}

log() {
  echo "[$(timestamp)] [pomodoro] $1" >> "$LOG_FILE"
}

mkdir -p "$LOG_DIR"
log "=== Pomodoro started ==="

if [ ! -f "$PROMPT_FILE" ]; then
  log "ERROR: pomodoro-prompt.md not found. Aborting."
  exit 1
fi

# Invoke Claude with full agency but restricted to our CLIs for external actions.
# Secrets never enter this session — bin/act loads them internally.
env -u CLAUDECODE claude \
  -p "$(cat "$PROMPT_FILE")" \
  --max-turns 30 \
  --max-budget-usd 2.00 \
  --output-format text \
  --allowedTools "Read,Write,Edit,Glob,Grep,Bash" \
  >> "$LOG_FILE" 2>&1 || log "Claude exited with error (may be non-fatal)"

log "=== Pomodoro finished ==="
