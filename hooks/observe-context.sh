#!/bin/bash

# Context Anchor Observer - Stop/PreCompact Hook Script
# Evaluates recent conversation and updates the context anchor file
# Uses model escalation based on delta size: haiku (<50KB) → sonnet (<200KB) → opus
# Deltas exceeding 500KB are capped to prevent context window overflow

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
ANCHOR_DIR="$HOME/.context-anchor-data"
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

# Find the parent session's anchor file for fork cold-start seeding.
# Forks share the same first user message timestamp as their parent.
# Scans sibling transcripts in the same project directory for a match.
# Outputs the parent anchor path to stdout if found; returns 1 otherwise.
find_parent_anchor() {
    local our_transcript="$1"
    local our_session="$2"
    local project_dir
    project_dir=$(dirname "$our_transcript")

    # Extract our first user message timestamp
    local our_first_ts
    our_first_ts=$(head -n 20 "$our_transcript" | jq -r 'select(.type == "user") | .timestamp' 2>/dev/null | head -n 1)

    if [ -z "$our_first_ts" ] || [ "$our_first_ts" = "null" ]; then
        return 1
    fi

    # Scan sibling transcripts for matching first user timestamp
    local sibling
    for sibling in "$project_dir"/*.jsonl; do
        [ -f "$sibling" ] || continue

        # Skip our own transcript
        local sibling_session
        sibling_session=$(basename "$sibling" | sed 's/\.jsonl$//' | cut -d'-' -f1-5)
        [ "$sibling_session" = "$our_session" ] && continue

        # Check first user message timestamp
        local sibling_ts
        sibling_ts=$(head -n 20 "$sibling" | jq -r 'select(.type == "user") | .timestamp' 2>/dev/null | head -n 1)

        if [ "$sibling_ts" = "$our_first_ts" ]; then
            # Found a sibling with matching first timestamp — check for anchor
            local sibling_anchor="$ANCHOR_DIR/$sibling_session.md"
            if [ -f "$sibling_anchor" ]; then
                echo "$sibling_anchor"
                return 0
            fi
        fi
    done

    return 1
}

# Preprocess transcript: filter noise, strip system reminders, annotate by role, drop empties
# Input: $1 = JSON array string (raw RECENT_CONTEXT from jq -s '.')
# Output: Preprocessed JSON array to stdout
# Falls back to raw input if jq processing fails
preprocess_transcript() {
    local raw_json="$1"

    if [ -z "$raw_json" ] || [ "$raw_json" = "null" ]; then
        echo "[]"
        return
    fi

    local processed
    processed=$(printf '%s' "$raw_json" | jq -c '
        # Stage 1: Keep only user and assistant messages
        [.[] | select(.type == "user" or .type == "assistant")] |

        # Stage 2: Strip <system-reminder> blocks from all string values
        map(walk(if type == "string" then
            gsub("<system-reminder>[\\s\\S]*?</system-reminder>"; "")
        else . end)) |

        # Stage 2.5: Drop messages emptied by system-reminder stripping
        # (must run before annotation, since prefixes like [USER] are non-empty)
        map(select(
            if .message.content == null then false
            elif (.message.content | type) == "string" then
                (.message.content | gsub("\\s"; "") | length > 0)
            elif (.message.content | type) == "array" then
                ([.message.content[] |
                    if .text then (.text | gsub("\\s"; ""))
                    elif .content then
                        if (.content | type) == "string" then (.content | gsub("\\s"; ""))
                        elif (.content | type) == "array" then ([.content[] | .text // ""] | join("") | gsub("\\s"; ""))
                        else ""
                        end
                    else ""
                    end
                ] | join("") | length > 0)
            else false
            end
        )) |

        # Stage 3: Annotate by role
        map(
            if .type == "user" then
                if (.message.content | type) == "string" then
                    { type: "user", ts: .timestamp,
                      content: ("[USER] " + .message.content) }
                else
                    { type: "user", ts: .timestamp,
                      content: (
                        [(.message.content // [])[] |
                            if .type == "tool_result" then
                                if (.content | type) == "string" then
                                    "[TOOL_RESULT] " + .content
                                elif (.content | type) == "array" then
                                    "[TOOL_RESULT] " + ([.content[] | .text // ""] | join("\n"))
                                else ""
                                end
                            else
                                "[USER] " + (.text // "")
                            end
                        ] | join("\n\n")
                      ) }
                end
            elif .type == "assistant" then
                { type: "assistant", ts: .timestamp,
                  content: (
                    [(.message.content // [])[] |
                        if .type == "text" then
                            "[AGENT] " + .text
                        elif .type == "tool_use" then
                            "[TOOL_CALL] " + .name
                        else ""
                        end
                    ] | join("\n\n")
                  ) }
            else empty
            end
        ) |

        # Stage 4: Drop messages with empty or whitespace-only content
        map(select(.content | gsub("\\s"; "") | length > 0))
    ' 2>/dev/null)

    if [ $? -ne 0 ] || [ -z "$processed" ]; then
        log "Preprocessing failed, falling back to raw delta"
        echo "$raw_json"
    else
        echo "$processed"
    fi
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
# Model escalation thresholds (bytes) — configurable via env vars
HAIKU_MAX=${CONTEXT_ANCHOR_HAIKU_MAX:-50000}
SONNET_MAX=${CONTEXT_ANCHOR_SONNET_MAX:-200000}
HARD_CAP=${CONTEXT_ANCHOR_HARD_CAP:-500000}

if [ "$HOOK_EVENT" = "PreCompact" ]; then
    # PreCompact: use last 30 lines for thorough final capture
    RECENT_CONTEXT=$(tail -n 30 "$TRANSCRIPT_PATH" | jq -s '.' 2>/dev/null)
    log "PreCompact: using last 30 lines of transcript"
else
    DELTA_BYTES=$((CURRENT_SIZE - LAST_OFFSET))

    if [ "$DELTA_BYTES" -gt "$HARD_CAP" ]; then
        ESCALATED_MODEL="opus"

        if [ ! -f "$ANCHOR_FILE" ]; then
            # Cold start: no anchor yet. Try to copy parent's anchor (fork scenario).
            PARENT_ANCHOR=$(find_parent_anchor "$TRANSCRIPT_PATH" "$SESSION_ID")
            if [ -n "$PARENT_ANCHOR" ]; then
                cp "$PARENT_ANCHOR" "$ANCHOR_FILE"
                log "Cold start: copied parent anchor from $PARENT_ANCHOR"
            else
                log "Cold start: no parent anchor found, proceeding without seed"
            fi
        fi

        # Normal hard cap: use last HARD_CAP bytes with opus
        # tail -c cuts mid-line, so skip the first partial line before jq parsing
        RECENT_CONTEXT=$(tail -c "$HARD_CAP" "$TRANSCRIPT_PATH" | tail -n +2 | jq -s '.' 2>/dev/null)
        log "Delta capped: ${DELTA_BYTES}b > hard cap ${HARD_CAP}b, using last ${HARD_CAP}b with opus"
    elif [ "$DELTA_BYTES" -gt "$SONNET_MAX" ]; then
        RECENT_CONTEXT=$(tail -c +$((LAST_OFFSET + 1)) "$TRANSCRIPT_PATH" | jq -s '.' 2>/dev/null)
        ESCALATED_MODEL="opus"
        log "Delta ${DELTA_BYTES}b > ${SONNET_MAX}b, escalating to opus"
    elif [ "$DELTA_BYTES" -gt "$HAIKU_MAX" ]; then
        RECENT_CONTEXT=$(tail -c +$((LAST_OFFSET + 1)) "$TRANSCRIPT_PATH" | jq -s '.' 2>/dev/null)
        ESCALATED_MODEL="sonnet"
        log "Delta ${DELTA_BYTES}b > ${HAIKU_MAX}b, escalating to sonnet"
    else
        RECENT_CONTEXT=$(tail -c +$((LAST_OFFSET + 1)) "$TRANSCRIPT_PATH" | jq -s '.' 2>/dev/null)
        log "Delta extraction from offset $LAST_OFFSET (delta size: ${DELTA_BYTES}b)"
    fi
fi

# Preprocess: strip system reminders, annotate by role, drop noise
RECENT_CONTEXT=$(preprocess_transcript "$RECENT_CONTEXT")
log "Preprocessed delta: ${#RECENT_CONTEXT} chars"

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

TRANSCRIPT ANNOTATIONS:
Messages are annotated by source:
- [USER]: Human input — the PRIMARY signal for intent and decisions
- [AGENT]: Assistant responses — may contain speculative proposals the user never confirmed
- [TOOL_CALL]: Tool invocations requested by the agent
- [TOOL_RESULT]: Tool outputs (file contents, command results, etc.)
Weight accordingly: a [USER] statement overrides an [AGENT] proposal. If the agent proposed something and the user did not explicitly confirm it, do not treat it as a decision.

ENVIRONMENT vs. FEATURES:
External tools, plugins, CLI utilities, linters, formatters, and development workflows visible in the conversation are part of the DEVELOPMENT ENVIRONMENT, not features being built. Do not include development tooling in Purpose or Current Direction unless the user explicitly states they are building that tool as part of the project.

CURRENT DIRECTION GUIDELINES (CRITICAL for PreCompact):
This section must contain ONLY work the user explicitly requested or confirmed. If the agent proposed something and the user did not respond to it, OMIT it. Err on the side of capturing less rather than fabricating direction from speculation.

EXISTING ANCHOR:
$EXISTING_ANCHOR

RECENT CONVERSATION (preprocessed transcript):
$RECENT_CONTEXT

Write the updated anchor file to: $ANCHOR_FILE

The anchor has three sections:
## Purpose — why this conversation exists, the human's intent and what success looks like
## Trajectory — key decisions that shaped the current path (replace superseded decisions, don't append)
## Current Direction — what the agent should do next and why, including recent user steering

Be thorough but concise. Every line must serve agent re-initialization. An agent reading only this anchor should understand: why it's here, how it got here, and what to do next."
else
    OBSERVER_PROMPT="You are a context curator. Evaluate whether the context anchor needs updating.

TRANSCRIPT ANNOTATIONS:
Messages are annotated by source:
- [USER]: Human input — the primary signal for intent and decisions
- [AGENT]: Assistant responses — may contain speculative proposals the user never confirmed
- [TOOL_CALL]: Tool invocations requested by the agent
- [TOOL_RESULT]: Tool outputs (file contents, command results, etc.)
Weight accordingly: a [USER] statement overrides an [AGENT] proposal. If the agent proposed something and the user did not explicitly confirm it, do not treat it as a decision.

ENVIRONMENT vs. FEATURES:
External tools, plugins, CLI utilities, linters, formatters, and development workflows visible in the conversation are part of the DEVELOPMENT ENVIRONMENT, not features being built. Do not include development tooling in Purpose or Current Direction unless the user explicitly states they are building that tool as part of the project.

CURRENT DIRECTION GUIDELINES:
This section must contain only work the user explicitly requested or confirmed. When uncertain whether something is a user decision or an agent suggestion, omit it. Err on the side of capturing less rather than fabricating direction.

EXISTING ANCHOR:
$EXISTING_ANCHOR

NEW CONVERSATION SINCE LAST CHECK (preprocessed transcript):
$RECENT_CONTEXT

If the conversation's purpose, key decisions, or current direction have meaningfully changed, write the updated anchor to: $ANCHOR_FILE

The anchor has three sections:
## Purpose — why this conversation exists
## Trajectory — key decisions (replace superseded ones, don't append)
## Current Direction — what should happen next and why

If nothing meaningful changed, do NOT write to the file. Keep the anchor concise — every line must serve re-initialization."
fi

# Model selection: explicit override > delta-based escalation > default (haiku)
if [ -n "$CONTEXT_ANCHOR_MODEL" ]; then
    OBSERVER_MODEL="$CONTEXT_ANCHOR_MODEL"
elif [ -n "$ESCALATED_MODEL" ]; then
    OBSERVER_MODEL="$ESCALATED_MODEL"
else
    OBSERVER_MODEL="haiku"
fi

log "Calling claude -p --model $OBSERVER_MODEL"

# Call claude in observer mode with tool access for file writing
CLAUDE_RESPONSE=$(echo "$OBSERVER_PROMPT" | (cd "$OBSERVER_WORK_DIR" && CONTEXT_ANCHOR_OBSERVER_MODE=true claude -p --model "$OBSERVER_MODEL" --allowedTools "Write,Read,Bash" --dangerously-skip-permissions) 2>/dev/null)
CLAUDE_EXIT=$?

# Always update the offset tracker — even on failure, so we don't retry
# the same oversized input in an infinite loop
echo "$CURRENT_SIZE" > "$STATE_FILE"

if [ $CLAUDE_EXIT -ne 0 ]; then
    log "Claude command failed with exit code $CLAUDE_EXIT"
    echo '{"decision": "approve", "reason": "Observer command failed"}'
    exit 0
fi

# Check if anchor was created/updated
if [ -f "$ANCHOR_FILE" ]; then
    ANCHOR_SIZE=$(wc -c < "$ANCHOR_FILE" | tr -d ' ')
    log "Anchor file exists ($ANCHOR_SIZE bytes)"
else
    log "No anchor file created (observer decided nothing meaningful changed)"
fi

echo '{"decision": "approve", "reason": "Observer completed"}'
exit 0
