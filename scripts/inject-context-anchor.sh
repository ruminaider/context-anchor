#!/bin/bash
# inject-context-anchor.sh
#
# Fired by SessionStart("compact") — AFTER context compaction completes.
# Reads the session-scoped context anchor file and outputs it to stdout,
# which gets injected as a <system-reminder> into the fresh post-compaction context.

LOG_DIR="$HOME/.context-anchor-logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/inject.log"

# Read hook input from stdin
INPUT=$(cat)

# Resolve project directory and session ID from hook input
CWD=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)

echo "[$(date -Iseconds)] SessionStart(compact) fired. CWD=$CWD SESSION=$SESSION_ID" >> "$LOG_FILE"

if [ -z "$CWD" ] || [ -z "$SESSION_ID" ]; then
    echo "[$(date -Iseconds)] Missing CWD or SESSION_ID, exiting." >> "$LOG_FILE"
    exit 0
fi

ANCHOR="$HOME/.context-anchor-data/$SESSION_ID.md"

if [ -f "$ANCHOR" ]; then
    echo "[$(date -Iseconds)] Anchor found, injecting ($(wc -c < "$ANCHOR") bytes)" >> "$LOG_FILE"
    echo "=== CONTEXT ANCHOR (Re-initialization Briefing) ==="
    echo "The following was captured during this conversation before context compaction."
    echo "Use this to re-orient yourself. Do not continue work without reading this first."
    echo "The compaction summary above may have lost important nuance — this anchor preserves it."
    echo ""
    cat "$ANCHOR"
    echo ""
    echo "=== END CONTEXT ANCHOR ==="
else
    echo "[$(date -Iseconds)] No anchor file at $ANCHOR" >> "$LOG_FILE"
fi
