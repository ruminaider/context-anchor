# Transcript Filtering and Observer Prompt Improvements

**Date:** 2026-02-06
**Status:** Design (not yet implemented)

## Problem

The context anchor observer misclassifies development environment context as project intent. When plugins like beads load on SessionStart, their system reminders appear in the transcript alongside actual user decisions. The observer model (typically haiku) reads both and cannot distinguish between "a tool running in the background" and "a feature the user wants to build."

This caused a real failure: the observer captured "Beads Issue Tracker" as a product feature in the anchor's Current Direction, when beads was merely a development tool active in the environment. The error persisted across multiple compactions because each subsequent observer reinforced the mistake.

Two distinct failure modes contribute:

1. **Environment bleed** — System reminders from plugins, linters, and hooks contaminate the transcript with non-intent content.
2. **Speculation amplification** — When the AI proposes something the user never confirmed, the observer treats the proposal as a decision.

## Solution

Preprocess the transcript delta before the observer sees it, and update the observer prompt to leverage the preprocessing.

### Part 1: Transcript Preprocessing

A new `preprocess_transcript()` function in `observe-context.sh` transforms the raw JSONL delta before passing it to the observer. Three operations run in sequence:

**Strip system reminders.** Remove all `<system-reminder>...</system-reminder>` blocks from message content fields. These blocks contain plugin hooks, linter notifications, session setup instructions, and environment metadata. None of this represents user intent.

The regex must handle multiline content within tags. Use non-greedy matching (`[\s\S]*?`) to avoid stripping content between separate reminder blocks in the same message.

**Annotate by role.** Label every remaining message with its source:

- `[USER]` — Human messages. Strongest signal for intent.
- `[AGENT]` — Claude's responses. Contain decisions but also speculation.
- `[TOOL_CALL]` — Tool invocations the agent requested.
- `[TOOL_RESULT]` — Outputs from tools (file contents, search results, command output).

These labels become the first line of each message's content, giving the observer an unambiguous signal about who said what.

**Drop empty messages.** After stripping system reminders, some messages contain only whitespace or nothing at all. Remove these to reduce noise and token cost.

Implementation uses a `jq` pipeline applied to the delta. The exact filter depends on the transcript JSONL schema (field names for role, content, tool metadata), which must be verified against a real transcript before writing the final version.

### Part 2: Observer Prompt Updates

Three additions to the observer prompt, applied to both the Stop and PreCompact variants.

**Annotation instructions.** Tell the observer what the labels mean and how to weight them:

> Messages are annotated by source. `[USER]` messages are the primary signal for intent — what the human actually wants. `[AGENT]` messages may contain speculative proposals the user never confirmed. `[TOOL_RESULT]` messages are outputs from tools, not decisions. Weight accordingly: a user statement overrides an agent proposal. If the agent proposed something and the user did not explicitly confirm it, do not treat it as a decision.

**Environment separation rule.** Directly address the failure mode that prompted this work:

> References to external tools, plugins, CLI utilities, or development workflows visible in the conversation are part of the development environment, NOT features being built. Do not include development tooling in Purpose or Current Direction unless the user explicitly states they are building that tool as part of the project.

**Current Direction grounding.** Constrain the most error-prone section:

> Current Direction must contain only work the user explicitly requested or confirmed. If you are unsure whether something is a user decision or an agent suggestion, omit it. Err on the side of capturing less rather than fabricating direction.

The PreCompact variant receives slightly stronger language, since it represents the last chance to capture context before compaction.

## Edge Cases

**System reminders containing project-relevant information.** Some reminders report file changes from linters or formatters. These are environment metadata, not intent. If a file change matters, the conversation itself will reference it.

**Nested or adjacent system-reminder tags.** Non-greedy matching ensures the regex strips each block independently without consuming content between two separate blocks in the same message.

**Large deltas dominated by tool results.** Tool results (file contents, search output) can overwhelm the delta. Annotations help the observer skip past these, and the existing model escalation logic (haiku for small deltas, sonnet/opus for larger ones) remains unchanged.

**jq filter failure.** If preprocessing fails for any reason, fall back to the raw unfiltered delta. This preserves current behavior — no worse than today.

## Changes Required

All changes are in `hooks/observe-context.sh`:

1. Add `preprocess_transcript()` function after line 100 (delta extraction)
2. Call the function on `$RECENT_CONTEXT` before building the observer prompt
3. Update the Stop observer prompt (lines 136-151) with annotation instructions, environment rule, and direction grounding
4. Update the PreCompact observer prompt (lines 119-134) with the same additions, using stronger language for the final-capture context

No new files. No new dependencies. No changes to `inject-context-anchor.sh` or `hooks.json`.

## Verification

After implementation, verify by:

1. Run the observer on a transcript that contains beads system reminders — confirm they are stripped
2. Check that annotations appear correctly on user, agent, and tool messages
3. Trigger a compaction in a session with active plugins — confirm the anchor's Current Direction contains only user-confirmed work, not environment tooling
4. Verify fallback: corrupt the jq filter temporarily and confirm the observer still runs with raw delta
