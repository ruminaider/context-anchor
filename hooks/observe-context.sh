#!/bin/bash

# Context Anchor Observer - Stop/PreCompact Hook Script
# Evaluates recent conversation and updates the context anchor file
# Uses another Claude instance (haiku) to semantically evaluate importance

# Prevent recursive calls from the observer's own Claude instance
if [ "$CONTEXT_ANCHOR_OBSERVER_MODE" = "true" ]; then
    echo '{"decision": "approve", "reason": "Running in observer mode, skipping"}'
    exit 0
fi

# Read the hook event data from stdin
EVENT=$(cat)

# Extract key information
SESSION_ID=$(echo "$EVENT" | jq -r '.session_id // "unknown"')
TRANSCRIPT_PATH=$(echo "$EVENT" | jq -r '.transcript_path // ""')
CWD=$(echo "$EVENT" | jq -r '.cwd // ""')
HOOK_EVENT=$(echo "$EVENT" | jq -r '.hook_event_name // "Stop"')

# Validate inputs
if [ -z "$CWD" ] || [ -z "$TRANSCRIPT_PATH" ] || [ ! -f "$TRANSCRIPT_PATH" ]; then
    echo '{"decision": "approve", "reason": "Missing CWD or transcript"}'
    exit 0
fi

# Setup paths
ANCHOR_DIR="$CWD/.claude/context-anchors"
ANCHOR_FILE="$ANCHOR_DIR/$SESSION_ID.md"
STATE_DIR="$HOME/.context-anchor-state"
STATE_FILE="$STATE_DIR/$SESSION_ID.offset"
LOG_DIR="$HOME/.context-anchor-logs"
OBSERVER_WORK_DIR="$HOME/.claude/context-anchor-observer"

mkdir -p "$ANCHOR_DIR" "$STATE_DIR" "$LOG_DIR" "$OBSERVER_WORK_DIR"

LOG_FILE="$LOG_DIR/observer.log"

log() {
    echo "[$(date -Iseconds)] [$HOOK_EVENT] $1" >> "$LOG_FILE"
}

log "Hook fired. Session=$SESSION_ID CWD=$CWD"

# Get the last processed byte offset
LAST_OFFSET=0
if [ -f "$STATE_FILE" ]; then
    LAST_OFFSET=$(cat "$STATE_FILE")
fi

# Get current transcript size
CURRENT_SIZE=$(wc -c < "$TRANSCRIPT_PATH" | tr -d ' ')

# Detect transcript shrinkage (compaction resets the file)
if [ "$LAST_OFFSET" -gt "$CURRENT_SIZE" ]; then
    log "Transcript shrank (offset=$LAST_OFFSET, size=$CURRENT_SIZE) — likely compacted, resetting offset"
    LAST_OFFSET=0
fi

# Skip if no new content (for Stop hook only — PreCompact always runs)
if [ "$HOOK_EVENT" = "Stop" ] && [ "$CURRENT_SIZE" -le "$LAST_OFFSET" ]; then
    log "No new content since last check (offset=$LAST_OFFSET, size=$CURRENT_SIZE)"
    echo '{"decision": "approve", "reason": "No new content"}'
    exit 0
fi

# Extract delta — only new content since last check
# For PreCompact, we take more context (last 30 lines) to be thorough
if [ "$HOOK_EVENT" = "PreCompact" ]; then
    RECENT_CONTEXT=$(tail -n 30 "$TRANSCRIPT_PATH" | jq -s '.' 2>/dev/null)
    log "PreCompact: using last 30 lines of transcript"
else
    RECENT_CONTEXT=$(tail -c +$((LAST_OFFSET + 1)) "$TRANSCRIPT_PATH" | jq -s '.' 2>/dev/null)
    log "Delta extraction from offset $LAST_OFFSET (delta size: $((CURRENT_SIZE - LAST_OFFSET)) bytes)"
fi

# Check if delta is too small to bother (< 200 bytes for Stop hooks)
DELTA_SIZE=${#RECENT_CONTEXT}
if [ "$HOOK_EVENT" = "Stop" ] && [ "$DELTA_SIZE" -lt 200 ]; then
    log "Delta too small ($DELTA_SIZE bytes), skipping"
    echo "$CURRENT_SIZE" > "$STATE_FILE"
    echo '{"decision": "approve", "reason": "Delta too small"}'
    exit 0
fi

# Read existing anchor if it exists
EXISTING_ANCHOR=""
if [ -f "$ANCHOR_FILE" ]; then
    EXISTING_ANCHOR=$(cat "$ANCHOR_FILE")
fi

# Build the observer prompt
if [ "$HOOK_EVENT" = "PreCompact" ]; then
    OBSERVER_PROMPT="You are a context curator performing a FINAL update before context compaction. This is the last chance to capture context before the conversation is summarized.

EXISTING ANCHOR:
$EXISTING_ANCHOR

RECENT CONVERSATION (JSONL transcript):
$RECENT_CONTEXT

Write the updated anchor file to: $ANCHOR_FILE

The anchor has three sections:
## Purpose — why this conversation exists, the human's intent and what success looks like
## Trajectory — key decisions that shaped the current path (replace superseded decisions, don't append)
## Current Direction — what the agent should do next and why, including recent user steering

Be thorough but concise. Every line must serve agent re-initialization. An agent reading only this anchor should understand: why it's here, how it got here, and what to do next."
else
    OBSERVER_PROMPT="You are a context curator. Evaluate whether the context anchor needs updating.

EXISTING ANCHOR:
$EXISTING_ANCHOR

NEW CONVERSATION SINCE LAST CHECK (JSONL transcript):
$RECENT_CONTEXT

If the conversation's purpose, key decisions, or current direction have meaningfully changed, write the updated anchor to: $ANCHOR_FILE

The anchor has three sections:
## Purpose — why this conversation exists
## Trajectory — key decisions (replace superseded ones, don't append)
## Current Direction — what should happen next and why

If nothing meaningful changed, do NOT write to the file. Keep the anchor concise — every line must serve re-initialization."
fi

# Model can be configured via CONTEXT_ANCHOR_MODEL env var (default: haiku)
OBSERVER_MODEL="${CONTEXT_ANCHOR_MODEL:-haiku}"

log "Calling claude -p --model $OBSERVER_MODEL"

# Call claude in observer mode with tool access for file writing
CLAUDE_RESPONSE=$(echo "$OBSERVER_PROMPT" | (cd "$OBSERVER_WORK_DIR" && CONTEXT_ANCHOR_OBSERVER_MODE=true claude -p --model "$OBSERVER_MODEL" --allowedTools "Write,Read,Bash" --dangerously-skip-permissions) 2>/dev/null)
CLAUDE_EXIT=$?

if [ $CLAUDE_EXIT -ne 0 ]; then
    log "Claude command failed with exit code $CLAUDE_EXIT"
    echo '{"decision": "approve", "reason": "Observer command failed"}'
    exit 0
fi

# Update the offset tracker
echo "$CURRENT_SIZE" > "$STATE_FILE"

# Check if anchor was created/updated
if [ -f "$ANCHOR_FILE" ]; then
    ANCHOR_SIZE=$(wc -c < "$ANCHOR_FILE" | tr -d ' ')
    log "Anchor file exists ($ANCHOR_SIZE bytes)"
else
    log "No anchor file created (observer decided nothing meaningful changed)"
fi

echo '{"decision": "approve", "reason": "Observer completed"}'
exit 0
