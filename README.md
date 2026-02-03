# context-anchor

A Claude Code plugin that preserves your conversation's intent, decisions, and direction across context compaction — so the agent never loses track of what you're building or why.

## Why Context Anchoring

Long Claude Code sessions accumulate context that matters: the original goal, trade-offs you evaluated, decisions you made, and the direction you steered toward. When the context window fills up, compaction compresses all of this into a summary — and summaries optimize for *what happened*, not *what matters*.

Context anchoring solves this by maintaining a **structured briefing document** alongside your conversation. Instead of relying on compaction to preserve the right things, the anchor explicitly tracks:

- **Purpose** — why this conversation exists and what success looks like
- **Trajectory** — the key decisions that shaped the current path
- **Current Direction** — what the agent should do next and why

The anchor is a **living snapshot, not a log**. It consolidates as the conversation evolves — replacing outdated decisions rather than appending to them. After compaction, the anchor is re-injected into the fresh context, giving the agent a clear re-initialization briefing that no summary could replicate.

### What Goes Wrong Without It

When Claude Code compacts a conversation without an anchor, three things break:

1. **Lost intent** — the original purpose and constraints disappear into a generic summary
2. **Lost decisions** — accumulated agreements are partially or fully dropped
3. **Lost steering** — recent directional input from the user is forgotten

The agent "resumes the last thing it was doing" without understanding *why* it was doing it. With an anchor, it re-initializes with full awareness of purpose, decisions, and direction.

## How It Works

The plugin maintains a lightweight **context anchor** — a briefing document with three sections (Purpose, Trajectory, Current Direction) that captures why the conversation exists, what was decided, and what should happen next.

A background Haiku observer updates the anchor as the conversation progresses. When compaction fires, the anchor is finalized and then re-injected into the fresh context window, ensuring the agent re-initializes with full awareness.

### Architecture

```
DURING CONVERSATION (Capture)
─────────────────────────────
User message → Agent responds → Stop hook fires
                                    │
                                    ▼
                          Haiku observer (prompt-type hook)
                          reads conversation + existing anchor
                          updates ~/.context-anchor-data/{session}.md
                          if trajectory changed


COMPACTION EVENT (Finalize + Inject)
────────────────────────────────────
Context window full (or /compact)
        │
        ▼
PreCompact hook fires (BLOCKING)
        │
        ▼
Haiku observer runs final update
synchronously — ensures anchor is
fully current before context disappears
        │
        ▼
Native compaction runs
(summarizes conversation its own way)
        │
        ▼
SessionStart("compact") hook fires
        │
        ▼
Shell script reads ~/.context-anchor-data/{session}.md
Outputs to stdout → injected as
<system-reminder> into fresh context
        │
        ▼
Agent re-initializes with:
  1. System prompt + CLAUDE.md
  2. Native compaction summary
  3. Context anchor (our injection) ← SURVIVES COMPACTION
```

### Hook Timing

Understanding *when* each hook fires relative to compaction is critical:

```
                    COMPACTION EVENT TIMELINE
                    ========================

    ┌─────────────┐     ┌──────────────┐     ┌───────────────────────┐
    │ PreCompact   │────▶│   Native     │────▶│ SessionStart("compact")│
    │ (BEFORE)     │     │  Compaction  │     │ (AFTER)               │
    │              │     │              │     │                       │
    │ Final anchor │     │ Summarizes   │     │ Reads anchor file     │
    │ update here  │     │ everything   │     │ Injects into fresh    │
    │              │     │ (including   │     │ context as            │
    │ Output gets  │     │  PreCompact  │     │ <system-reminder>     │
    │ COMPACTED    │     │  output)     │     │                       │
    │ away ⚠️      │     │              │     │ Output SURVIVES ✓     │
    └─────────────┘     └──────────────┘     └───────────────────────┘
```

**Key insight**: `PreCompact` output gets compacted away — it's part of the pre-compaction context. `SessionStart("compact")` output enters the *fresh* post-compaction context and persists. That's why the plugin uses PreCompact for the final *capture* and SessionStart for the *injection*.

### Component Roles

| Component | Hook Type | Trigger | Job |
|-----------|-----------|---------|-----|
| **Periodic Observer** | `Stop` (prompt, Haiku) | After each agent turn | Updates anchor if trajectory changed |
| **Final Observer** | `PreCompact` (prompt, Haiku, blocking) | Before compaction | Last-chance thorough anchor update |
| **Injector** | `SessionStart("compact")` (command) | After compaction | Reads anchor, outputs to stdout → system reminder |

## The Anchor Format

Each session gets its own anchor at `~/.context-anchor-data/{session-id}.md` with three sections:

```markdown
## Purpose
Why this conversation exists. The human's original intent and
what success looks like.

## Trajectory
Key decisions that shaped the current path. Each a single
statement of what was decided and why. Superseded decisions
are removed.

## Current Direction
What the agent should be doing right now and the reasoning
behind it. Includes any recent steering from the user.
```

### Anchor Principles

- **Living snapshot, not a log** — the observer replaces, never appends
- **Signal density over token count** — no hard cap, but every line must serve re-initialization
- **Current state only** — no timestamps, no history, no changelog
- **Every line answers one of**: why are we here, what did we decide, or what should happen next

## Installation

### Prerequisites

- **Claude Code** with hooks support enabled
- **Claude Pro or Max subscription** — the plugin uses prompt-type hooks (Haiku observer), so no API key is required

### Install the Plugin

From within Claude Code, run:

```bash
/install-plugin https://github.com/ruminaider/context-anchor
```

### Configure Your Project

Add this to your project's `CLAUDE.md` so the agent knows how to use the anchor after compaction:

```markdown
## Context Anchor System

After context compaction, you will receive a CONTEXT ANCHOR system reminder
containing your re-initialization briefing. It has three sections: Purpose,
Trajectory, and Current Direction. Read it before taking any action. Do not
resume work based solely on the compaction summary — the anchor contains the
human's intent and key decisions that the summary may have lost.
```

### Verify It's Working

After a few turns of conversation, check the observer log:

```bash
cat ~/.context-anchor-logs/observer.log
```

You should see `[Stop] Hook fired` entries showing the observer evaluating each turn. Once enough meaningful context accumulates, an anchor file will appear in `~/.context-anchor-data/`.

## How It Differs from Episodic Memory

| | Context Anchor | Episodic Memory |
|---|---|---|
| **Question answered** | "If you woke up right now, what do you need to know?" | "What happened in past sessions?" |
| **Scope** | Single conversation | Cross-session |
| **Growth pattern** | Consolidates (gets tighter over time) | Appends (grows over time) |
| **Purpose** | Re-initialization after compaction | Historical recall |

## Design Decisions

| Decision | Rationale |
|----------|-----------|
| Capture is agent-driven (Haiku), not rule-based | A fixed rubric over-captures or under-captures. A model reading the conversation applies judgment like a human note-taker. |
| Injection is hook-driven (shell script), not agent-driven | Injection must be guaranteed and mechanical. No compliance risk. |
| Prompt-type hooks, not API calls | Works on Pro/Max subscriptions without requiring ANTHROPIC_API_KEY. |
| SessionStart for injection, not PreCompact | PreCompact output gets compacted away. SessionStart("compact") output persists. |
| Markdown format, not JSON | The observer is a language model. Natural language is what it writes and reads best. |
| No hard token cap | Simple conversations need little context; dense discussions need more. Signal density is the constraint, not a number. |

## License

MIT
