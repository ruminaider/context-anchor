#!/bin/bash
# inject-context-anchor.sh
#
# Fired by SessionStart("compact") — AFTER context compaction completes.
# Reads the context anchor file and outputs it to stdout, which gets
# injected as a <system-reminder> into the fresh post-compaction context.

# Read hook input from stdin
INPUT=$(cat)

# Resolve project directory from hook input
CWD=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)

if [ -z "$CWD" ]; then
    exit 0
fi

ANCHOR="$CWD/.claude/context-anchor.md"

if [ -f "$ANCHOR" ]; then
    echo "=== CONTEXT ANCHOR (Re-initialization Briefing) ==="
    echo "The following was captured during this conversation before context compaction."
    echo "Use this to re-orient yourself. Do not continue work without reading this first."
    echo "The compaction summary above may have lost important nuance — this anchor preserves it."
    echo ""
    cat "$ANCHOR"
    echo ""
    echo "=== END CONTEXT ANCHOR ==="
fi
