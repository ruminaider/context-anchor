#!/bin/bash
# diagnostics.sh
#
# Run this to check if context-anchor is working in the current project.
# Usage: bash /path/to/context-anchor/scripts/diagnostics.sh [project-dir]

PROJECT_DIR="${1:-$(pwd)}"
ANCHOR="$PROJECT_DIR/.claude/context-anchor.md"
LOG_DIR="$HOME/.context-anchor-logs"

echo "=== context-anchor diagnostics ==="
echo ""

# Check 1: Plugin installed?
echo "1. Plugin installation:"
if claude plugin list 2>/dev/null | grep -q "context-anchor"; then
    echo "   ✓ Plugin is installed"
else
    echo "   ✗ Plugin not found in 'claude plugin list'"
    echo "   Run: /plugin marketplace add ruminaider/context-anchor"
fi
echo ""

# Check 2: Anchor file exists?
echo "2. Anchor file ($ANCHOR):"
if [ -f "$ANCHOR" ]; then
    echo "   ✓ File exists"
    echo "   Size: $(wc -c < "$ANCHOR") bytes"
    echo "   Last modified: $(stat -f '%Sm' "$ANCHOR" 2>/dev/null || stat -c '%y' "$ANCHOR" 2>/dev/null)"
    echo ""
    echo "   Contents:"
    echo "   ─────────"
    sed 's/^/   /' "$ANCHOR"
    echo "   ─────────"
else
    echo "   ✗ File does not exist"
    echo "   The Stop hook (Haiku observer) has not created an anchor yet."
    echo "   This could mean:"
    echo "     - The hook hasn't fired (no conversation turns completed)"
    echo "     - The prompt-type hook doesn't have Write tool access"
    echo "     - The hook decided nothing meaningful happened yet"
fi
echo ""

# Check 3: .claude directory exists?
echo "3. Project .claude directory:"
if [ -d "$PROJECT_DIR/.claude" ]; then
    echo "   ✓ Exists"
else
    echo "   ✗ Does not exist — hook may not be able to create the anchor"
fi
echo ""

# Check 4: Hook logs (if we add logging)
echo "4. Hook execution logs ($LOG_DIR):"
if [ -d "$LOG_DIR" ]; then
    RECENT=$(find "$LOG_DIR" -name "*.log" -mmin -60 2>/dev/null | head -5)
    if [ -n "$RECENT" ]; then
        echo "   Recent logs (last 60 min):"
        for f in $RECENT; do
            echo "   - $(basename "$f"): $(tail -1 "$f")"
        done
    else
        echo "   No recent log activity"
    fi
else
    echo "   No log directory found (logging not enabled)"
fi
echo ""

# Check 5: gitignore
echo "5. Gitignore check:"
if [ -f "$PROJECT_DIR/.gitignore" ]; then
    if grep -q "context-anchor" "$PROJECT_DIR/.gitignore"; then
        echo "   ✓ context-anchor.md is in .gitignore"
    else
        echo "   ⚠ context-anchor.md is NOT in .gitignore"
        echo "   Add '.claude/context-anchor.md' to your .gitignore"
    fi
else
    echo "   ⚠ No .gitignore found"
fi

echo ""
echo "=== end diagnostics ==="
