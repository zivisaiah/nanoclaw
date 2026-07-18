# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

---

You are a NanoClaw agent. Your name, destinations, and message-sending rules are provided in the runtime system prompt at the top of each turn.

## Communication

Be concise — every message costs the reader's attention. Prefer outcomes over play-by-play; when the work is done, the final message should be about the result, not a transcript of what you did.

## Workspace

Files you create are saved in `/workspace/agent/`. Use this for notes, research, or anything that should persist across turns in this group.

The file `CLAUDE.local.md` in your workspace is your per-group memory. Record things there that you'll want to remember in future sessions — user preferences, project context, recurring facts. Keep entries short and structured.

## Memory

When the user shares any substantive information with you, it must be stored somewhere you can retrieve it when relevant. If it's information that is pertinent to every single conversation turn it should be put into CLAUDE.local.md. Otherwise, create a system for storing the information depending on its type - e.g. create a file of people that the user mentions so you can keep track or a file of projects. For every file you create, add a concise reference in your CLAUDE.local.md so you'll be able to find it in future conversations.

A core part of your job and the main thing that defines how useful you are to the user is how well you do in creating these systems for organizing information. These are your systems that help you do your job well. Evolve them over time as needed.

## Conversation history

The `conversations/` folder in your workspace holds searchable transcripts of past sessions with this group. Use it to recall prior context when a request references something that happened before. For structured long-lived data, prefer dedicated files (`customers.md`, `preferences.md`, etc.); split any file over ~500 lines into a folder with an index.

---

## Development Guide

The rest of this file is for Claude Code working on the agent-runner source.

### Runtime

The container runs **Bun**, not Node. The host runs Node (pnpm). They only communicate via session DBs — no shared modules.

### Commands

```bash
# From container/agent-runner/
bun install              # after editing deps in package.json
bun test                 # run all tests (uses bun:test, NOT vitest)
bun run typecheck        # tsc --noEmit

# From project root
./container/build.sh     # rebuild nanoclaw-agent:latest Docker image
```

Run a single test file: `bun test src/formatter.test.ts`

### Architecture

**Source is not baked into the image.** The host mounts `agent-runner/src/` read-only at `/app/src` at runtime. Image rebuilds are only needed for Dockerfile changes (deps, CLIs, system packages).

**Mount layout inside the container:**
```
/workspace/
  inbound.db        ← host writes, container reads (READ-ONLY, journal_mode=DELETE)
  outbound.db       ← container writes, host reads
  .heartbeat        ← touched every poll iteration for liveness detection
  agent/            ← agent group folder (CLAUDE.md, container.json, working files)
  extra/            ← optional additional mount directories
/app/src/           ← agent-runner source (RO bind mount from host)
/app/skills/        ← container skills (RO)
```

**Poll loop** (`src/poll-loop.ts`): reads `inbound.db` → formats messages → calls provider → streams result → writes `outbound.db`. Concurrently polls for follow-up messages during active queries and pushes them via `provider.push()`.

**Message dispatch**: The agent wraps output in `<message to="name">...</message>` blocks. The poll loop parses these and writes each block to `outbound.db` targeting the named destination. Bare text outside these blocks is scratchpad and is not delivered.

**Provider abstraction** (`src/providers/`): `AgentProvider` interface abstracts Claude, OpenCode, and any future providers. Each provider handles its own continuation (session resumption), model config, and streaming. `factory.ts` instantiates by name; `index.ts` barrel self-registers providers on import.

**MCP tools** (`src/mcp-tools/`): Nanoclaw's built-in MCP server runs as a subprocess. Tools self-register via `registerTools([...])` at module scope — add a new tool module and import it in `index.ts`. Tool modules: `core` (send/edit messages, reactions), `scheduling`, `interactive` (ask_user_question), `agents` (a2a), `self-mod` (install_packages, add_mcp_server).

**Config** (`src/config.ts`): Read-only from `/workspace/agent/container.json` at startup. Contains provider, model, assistantName, agentGroupId, mcpServers, etc.

### Critical SQLite Rules

- `inbound.db` **must** stay `journal_mode=DELETE` (set by host). WAL mode breaks cross-mount visibility on VirtioFS — the container would read a stale snapshot and never see new host messages.
- Use `$name` parameters in Bun SQLite (e.g., `.run({ $id: msg.id })`). Unlike `better-sqlite3`, `bun:sqlite` does NOT auto-strip the `$` prefix.
- Every reader of `inbound.db` that needs fresh data should call `openInboundDb()` (fresh connection each call), not `getInboundDb()` (cached singleton).

### Testing

- Import from `bun:test`, never `vitest`. The host's `vitest.config.ts` excludes the `container/` tree.
- Test files live alongside source (`*.test.ts`).
- After editing `agent-runner/` deps, run `cd container/agent-runner && bun install` and commit the updated `bun.lock`. Do not run `pnpm install` here.

### Extension Points

`MODULE-HOOK:<name>:start` / `:end` comment pairs in `poll-loop.ts` mark where optional modules inject code (e.g., scheduling pre-task scripts). The scheduling module is dynamically imported; without it the hook block is a no-op.

### Container Image

Build args in `Dockerfile`:
- `CLAUDE_CODE_VERSION`, `AGENT_BROWSER_VERSION`, `VERCEL_VERSION`, `BUN_VERSION`, `PNPM_VERSION` — pin deliberately, never bump blindly
- `INSTALL_CJK_FONTS` — opt-in for Chinese/Japanese/Korean font support (~200MB)

pnpm `only-built-dependencies` in the Dockerfile is load-bearing: `agent-browser` needs its postinstall chmod, and `@anthropic-ai/claude-code` needs its native binary download. Do not remove these entries without understanding the consequence.
