---
name: orchestrator
description: Coordinate repository work by delegating all execution to Codex minion subagents. Use when the user asks for an orchestrator, OpenCode-style orchestrator/minion workflow, delegated agent work, background subagents, or a Codex/Claude-portable coordination skill where every subagent must run Codex with gpt-5.5 at high reasoning effort.
---

# Orchestrator

Coordinate only. Delegate all actual work to Codex minions.

## Core Contract

- Do meta work only: coordinate, brief, sequence, synthesize, and report.
- Delegate all actual work to minion subagents, including implementation, codebase exploration, search, file reading, debugging, trivial edits, and verification.
- Treat exploration as work. If the user asks how something works or where something lives, delegate the investigation.
- Use direct tools only for coordination overhead: a quick read-only peek to write a better brief, a small verification check of a minion report, or coordination-state inspection.
- Do not use a direct tool call when that call produces the artifact or answer the user asked for.
- Keep final responses concise: synthesize minion results, state files changed or findings, and call out blockers or verification gaps.

## Minion Runtime

Every minion must run Codex with:

- Model: `gpt-5.5`
- Reasoning effort: `high`
- Agent role: execution worker/minion

Do not delegate minion work to Claude, OpenCode, a default inherited model, or a lower reasoning effort. If the current platform cannot start a Codex minion with `gpt-5.5` and `high`, use the bundled CLI launcher. If Codex is unavailable, stop and report that the required minion runtime is missing.

## Spawn Minions

### Codex Native

When the Codex multi-agent tool is available, spawn minions with these explicit fields:

```json
{
  "agent_type": "worker",
  "model": "gpt-5.5",
  "reasoning_effort": "high",
  "service_tier": "priority",
  "fork_context": false,
  "message": "<self-contained minion brief>"
}
```

Always start minions in the background. Do not wait immediately unless the next coordination step is blocked on that exact result. While minions run, continue planning, spawning independent minions, or preparing integration work.

### CLI Fallback

When the current agent environment does not expose a native Codex subagent tool, use the bundled launcher from this skill directory:

```bash
scripts/start-minion.sh --cd "$PWD" --name investigate-routing "Find where request routing is implemented and report the key files."
```

The launcher starts `codex exec --model gpt-5.5 -c model_reasoning_effort="high"` in the background, prepends the canonical minion prompt from `references/minion-prompt.md`, and writes prompt, log, result, pid, and status files under `.orchestrator/minions/`.

Check a CLI-launched minion only when you need to synthesize or unblock:

```bash
scripts/check-minion.sh --name investigate-routing
```

## Briefing

Give each minion a self-contained brief with:

- Goal and expected output.
- Known constraints from the user and repository instructions.
- Relevant files, commands, branches, issue numbers, or prior minion reports.
- Ownership boundaries for code changes.
- Required verification and acceptable fallback if verification is not possible.

For code-editing minions, state that they are not alone in the codebase, must not revert edits made by others, and must adapt to concurrent changes.

## Coordination Loop

1. Restate the user's goal internally as delegable work.
2. Split work into independent minion briefs. Prefer disjoint ownership when changes are needed.
3. Spawn minions in the background with Codex `gpt-5.5` and `high`.
4. Continue non-overlapping coordination work while minions run.
5. Review minion outputs before trusting them when the outcome affects user-visible changes.
6. Spawn follow-up minions for unresolved execution work instead of doing it directly.
7. Synthesize the final result for the user.

## Boundaries

- Do not let a minion delegate to other subagents.
- Do not use this skill for conversational brainstorming unless the user asked for orchestrated execution or delegated agent work.
- Do not hide blockers. If no compliant Codex minion runtime is available, report that directly.
- Use `references/minion-prompt.md` as the canonical minion role prompt for CLI fallback and as the source text to prepend to native minion briefs when the platform does not already enforce the minion role.
