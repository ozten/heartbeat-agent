#!/bin/bash
# think.sh — Heartbeat thinking loop
# Reads heartbeat state, detects new content, invokes Claude for analysis.
# Called by heartbeat.sh after data collection.
#
# Claude's tools are restricted to Read/Write/Edit/Glob/Grep — no Bash.
# Intents (actions to take) are enqueued via bin/enqueue, not executed here.

set -uo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_DIR="$PROJECT_DIR/logs"
LOG_FILE="$LOG_DIR/heartbeat.log"
HEARTBEAT_STATE="$LOG_DIR/heartbeat-state.json"
ANALYSIS_STATE="$LOG_DIR/analysis-state.json"
ANALYSIS_PROMPT="$PROJECT_DIR/heartbeat/analysis-prompt.md"
SLACK_SEND="$PROJECT_DIR/slack/send.sh"
ENQUEUE="$PROJECT_DIR/bin/enqueue"

timestamp() {
  date '+%Y-%m-%d %H:%M:%S'
}

log() {
  echo "[$(timestamp)] [think] $1" >> "$LOG_FILE"
}

log "--- Think step started ---"

if [ ! -f "$HEARTBEAT_STATE" ]; then
  log "ERROR: heartbeat-state.json not found. Skipping."
  exit 1
fi

if [ ! -f "$ANALYSIS_STATE" ]; then
  log "analysis-state.json not found. Initializing empty state."
  cat > "$ANALYSIS_STATE" <<'SEED'
{
  "last_analysis": null,
  "digest": null,
  "post_ids_seen": [],
  "brain_notes_written": []
}
SEED
fi

if [ ! -f "$ANALYSIS_PROMPT" ]; then
  log "ERROR: analysis-prompt.md not found. Skipping."
  exit 1
fi

# Extract current feed post IDs from heartbeat state
CURRENT_IDS=$(python3 -c "
import json, sys
with open('$HEARTBEAT_STATE') as f:
    data = json.load(f)
feed = data.get('feed_snippet', {})
posts = feed.get('posts', []) if isinstance(feed, dict) else []
for p in posts:
    print(p.get('id', ''))
" 2>/dev/null || true)

# Extract previously seen IDs from analysis state
SEEN_IDS=$(python3 -c "
import json
with open('$ANALYSIS_STATE') as f:
    data = json.load(f)
for pid in data.get('post_ids_seen', []):
    print(pid)
" 2>/dev/null || true)

# Find new post IDs (in current but not in seen)
NEW_IDS=$(comm -23 <(echo "$CURRENT_IDS" | sort) <(echo "$SEEN_IDS" | sort) 2>/dev/null || true)
NEW_COUNT=$(echo "$NEW_IDS" | grep -c '[a-f0-9]' 2>/dev/null || true)

log "Feed posts: $(echo "$CURRENT_IDS" | grep -c '[a-f0-9]' 2>/dev/null || true), Previously seen: $(echo "$SEEN_IDS" | grep -c '[a-f0-9]' 2>/dev/null || true), New: $NEW_COUNT"

if [ "$NEW_COUNT" -eq 0 ]; then
  log "No new posts detected. Skipping Claude invocation."
  log "--- Think step finished (nothing new) ---"
  exit 0
fi

log "New post IDs: $NEW_IDS"

# Build the prompt by filling in the analysis-prompt.md template
PROMPT_FILE=$(mktemp /tmp/agent-think-XXXXXX.md)

python3 -c "
import json, sys
heartbeat_path = '$HEARTBEAT_STATE'
analysis_path = '$ANALYSIS_STATE'
template_path = '$ANALYSIS_PROMPT'
output_path = '$PROMPT_FILE'

with open(heartbeat_path) as f:
    heartbeat = json.load(f)
with open(analysis_path) as f:
    analysis = json.load(f)
with open(template_path) as f:
    template = f.read()

feed_posts = json.dumps(heartbeat.get('feed_snippet', {}), indent=2)
dm_status = json.dumps(heartbeat.get('dm_check', {}), indent=2)

digest = analysis.get('digest')
if digest:
    prev_lines = ['Last digest: ' + digest]
    notes = analysis.get('brain_notes_written', [])
    if notes:
        prev_lines.append('Notes written last time: ' + ', '.join(notes))
    previous_analysis = '\n'.join(prev_lines)
else:
    previous_analysis = 'No previous analysis available (first run).'

result = template.replace('{{FEED_POSTS}}', feed_posts)
result = result.replace('{{DM_STATUS}}', dm_status)
result = result.replace('{{PREVIOUS_ANALYSIS}}', previous_analysis)

with open(output_path, 'w') as f:
    f.write(result)
" 2>/dev/null

if [ ! -s "$PROMPT_FILE" ]; then
  log "ERROR: Failed to build prompt. Skipping."
  rm -f "$PROMPT_FILE"
  exit 1
fi

log "Invoking Claude for analysis..."

CLAUDE_OUTPUT_FILE=$(mktemp /tmp/agent-think-out-XXXXXX.txt)
env -u CLAUDECODE claude -p "$(cat "$PROMPT_FILE")" \
  --max-turns 15 \
  --max-budget-usd 1.00 \
  --output-format text \
  --allowedTools "Read,Write,Edit,Glob,Grep" \
  > "$CLAUDE_OUTPUT_FILE" 2>>"$LOG_FILE" || true

rm -f "$PROMPT_FILE"

if [ ! -s "$CLAUDE_OUTPUT_FILE" ]; then
  log "ERROR: Claude returned empty output."
  rm -f "$CLAUDE_OUTPUT_FILE"
  log "--- Think step finished (error) ---"
  exit 1
fi

CLAUDE_OUTPUT_SIZE=$(wc -c < "$CLAUDE_OUTPUT_FILE" | tr -d ' ')
log "Claude output received ($CLAUDE_OUTPUT_SIZE bytes)"

ANALYSIS_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
PARSE_RESULT_FILE=$(mktemp /tmp/agent-think-parse-XXXXXX.txt)

python3 -c "
import json, sys

output_path = '$CLAUDE_OUTPUT_FILE'
analysis_path = '$ANALYSIS_STATE'
result_path = '$PARSE_RESULT_FILE'
analysis_ts = '$ANALYSIS_TS'

with open(output_path) as f:
    raw = f.read()

start = raw.find('{')
end = raw.rfind('}')
if start == -1 or end == -1:
    with open(result_path, 'w') as f:
        f.write('PARSE_ERROR\n')
    sys.exit(0)

json_str = raw[start:end+1]
try:
    data = json.loads(json_str)
except json.JSONDecodeError:
    with open(result_path, 'w') as f:
        f.write('PARSE_ERROR\n')
    sys.exit(0)

state = {
    'last_analysis': analysis_ts,
    'digest': data.get('digest'),
    'post_ids_seen': data.get('post_ids_seen', []),
    'brain_notes_written': data.get('brain_notes_written', []),
    'notable_posts': data.get('notable_posts', []),
    'engagement_ideas': data.get('engagement_ideas', []),
    'intents': data.get('intents', []),
    'notify_austin': data.get('notify_austin', False),
    'austin_message': data.get('austin_message')
}

try:
    with open(analysis_path) as f:
        prev = json.load(f)
    prev_ids = set(prev.get('post_ids_seen', []))
except Exception:
    prev_ids = set()

all_ids = sorted(set(state['post_ids_seen']) | prev_ids)
state['post_ids_seen'] = all_ids

with open(analysis_path, 'w') as f:
    json.dump(state, f, indent=2)
    f.write('\n')

notify = str(data.get('notify_austin', False))
message = str(data.get('austin_message') or '')
with open(result_path, 'w') as f:
    f.write('OK\n')
    f.write(notify + '\n')
    f.write(message + '\n')
" 2>/dev/null

PARSE_STATUS=$(head -1 "$PARSE_RESULT_FILE" 2>/dev/null || echo "PARSE_ERROR")

if [ "$PARSE_STATUS" = "PARSE_ERROR" ]; then
  log "ERROR: Failed to parse Claude JSON output."
  cp "$CLAUDE_OUTPUT_FILE" "$LOG_DIR/think-raw-output.txt"
  rm -f "$CLAUDE_OUTPUT_FILE" "$PARSE_RESULT_FILE"
  log "--- Think step finished (parse error) ---"
  exit 1
fi

rm -f "$CLAUDE_OUTPUT_FILE"
log "Analysis saved to analysis-state.json"

# Enqueue any intents the analysis produced
if [ -x "$ENQUEUE" ]; then
  INTENT_COUNT=$(python3 -c "
import json
with open('$ANALYSIS_STATE') as f:
    state = json.load(f)
print(len(state.get('intents', [])))
" 2>/dev/null || echo "0")

  if [ "$INTENT_COUNT" -gt 0 ]; then
    log "Enqueueing $INTENT_COUNT intent(s)..."
    python3 -c "
import json, subprocess, sys

analysis_path = '$ANALYSIS_STATE'
enqueue = '$ENQUEUE'

with open(analysis_path) as f:
    state = json.load(f)

for intent in state.get('intents', []):
    action = intent.get('action', '')
    target = intent.get('target', '')
    rationale = intent.get('rationale', '')
    context = intent.get('context', '')
    if not action or not rationale:
        continue
    cmd = [enqueue, 'add', '--action', action, '--rationale', rationale]
    if target:
        cmd += ['--target', target]
    if context:
        cmd += ['--context', context]
    result = subprocess.run(cmd, capture_output=True, text=True)
    print(result.stdout.strip(), file=sys.stderr)
" 2>>"$LOG_FILE" || log "Intent enqueueing had errors (non-fatal)"
  else
    log "No intents to enqueue."
  fi
else
  log "WARNING: bin/enqueue not found — intents not queued"
fi

# Notify human if needed
NOTIFY=$(sed -n '2p' "$PARSE_RESULT_FILE")
MESSAGE=$(sed -n '3p' "$PARSE_RESULT_FILE")
rm -f "$PARSE_RESULT_FILE"

if [ "$NOTIFY" = "True" ] && [ -n "$MESSAGE" ] && [ -f "$SLACK_SEND" ]; then
  log "Notifying human via Slack: $MESSAGE"
  bash "$SLACK_SEND" "$MESSAGE" 2>>"$LOG_FILE" || log "Slack notification failed (non-fatal)"
else
  log "No human notification needed."
fi

log "--- Think step finished ---"
