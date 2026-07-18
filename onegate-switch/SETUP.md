# Claritas OneCLI <-> OneGate deterministic switch — one-time setup

Goal: a pure-bash toggle (no LLM) that flips my egress between hosted OneCLI
(current, default) and fleet OneGate, and always works even when OneGate is down.

You do steps 1-6 ONCE. After that, switching is just:

    nanoclaw-proxy.sh onegate      # try OneGate
    nanoclaw-proxy.sh onecli       # go back (safe default)
    nanoclaw-proxy.sh direct       # no proxy at all (if both gateways are off)
    nanoclaw-proxy.sh status

No rebuild is ever needed to switch again.

---

## What's in this kit (all in my workspace, I also send them to you on Telegram)

- `onegate-proxy.ts`  -> new host source file
- container-runner.ts patch (below, step 3)
- `nanoclaw-proxy.sh`  -> the toggle
- `com.nanoclaw.onegate-tunnel.plist` -> the persistent SSH tunnel
- this SETUP.md

---

## 1. Create the config dir and drop in the secrets

```bash
mkdir -p ~/.nanoclaw-onegate
chmod 700 ~/.nanoclaw-onegate

# Locate the 3 files I keep in my mounted workspace (they are already on this Mac):
BASE=$(dirname "$(find /Users/ziv/Work/clarity -name claritas-onegate-agent-token.txt 2>/dev/null | head -n1)")
echo "found secrets in: $BASE"

cp "$BASE/claritas-onegate-agent-token.txt" ~/.nanoclaw-onegate/agent-token
cp "$BASE/onegate-rootCA.pem"               ~/.nanoclaw-onegate/rootCA.pem
cp "$BASE/nano_vm_ed25519"                  ~/.nanoclaw-onegate/vm_ed25519

chmod 600 ~/.nanoclaw-onegate/agent-token ~/.nanoclaw-onegate/vm_ed25519
chmod 644 ~/.nanoclaw-onegate/rootCA.pem

# Config + start in the SAFE mode (onecli)
printf 'PROXY_PORT=18443\n' > ~/.nanoclaw-onegate/config.env
printf 'onecli\n'           > ~/.nanoclaw-onegate/mode
```

If `find` returns nothing, tell me and I'll give you the exact workspace path.
`nano_vm_ed25519` is my VM SSH key. If it's not next to the token, I'll point you at it.

## 2. Add the OneGate host source file

Copy `onegate-proxy.ts` into the host source tree:

```bash
cp <this-kit>/onegate-proxy.ts /Users/ziv/Work/clarity/nanoclaw-v2/src/onegate-proxy.ts
```

## 3. Patch container-runner.ts (one small, gated change)

Edit `/Users/ziv/Work/clarity/nanoclaw-v2/src/container-runner.ts`.

**3a. Add the import** near the other local imports at the top (anywhere in the
import block):

```ts
import { readProxyMode, applyOneGateContainerConfig, applyDirectContainerConfig } from './onegate-proxy.js';
```

**3b. Find this existing block** (around the OneCLI apply, ~line 489). It looks
like this (indentation may differ slightly, match your file):

```ts
    if (agentIdentifier) {
      await onecli.ensureAgent({ name: agentGroup.name, identifier: agentIdentifier });
    }
    const onecliApplied = await onecli.applyContainerConfig(args, { addHostMapping: false, agent: agentIdentifier });
    if (!onecliApplied) {
      throw new Error('OneCLI gateway not applied — refusing to spawn container without credentials');
    }
    log.info('OneCLI gateway applied', { containerName });
```

**Replace that whole block with** (keep your file's indentation):

```ts
    // Proxy gateway, read fresh from ~/.nanoclaw-onegate/mode at every spawn so
    // switching needs no rebuild — see nanoclaw-proxy.sh.
    //   onegate -> fleet OneGate via SSH tunnel
    //   direct  -> NO proxy (ultimate net if both gateways are off)
    //   onecli  -> hosted OneCLI (default, today's behavior)
    const proxyMode = readProxyMode();
    if (proxyMode === 'onegate') {
      applyOneGateContainerConfig(args, { agent: agentIdentifier, containerName });
      log.info('OneGate gateway applied', { containerName });
    } else if (proxyMode === 'direct') {
      applyDirectContainerConfig(args, { containerName });
    } else {
      if (agentIdentifier) {
        await onecli.ensureAgent({ name: agentGroup.name, identifier: agentIdentifier });
      }
      const onecliApplied = await onecli.applyContainerConfig(args, { addHostMapping: false, agent: agentIdentifier });
      if (!onecliApplied) {
        throw new Error('OneCLI gateway not applied — refusing to spawn container without credentials');
      }
      log.info('OneCLI gateway applied', { containerName });
    }
```

That is the ONLY code change. In `onecli` mode the behavior is byte-for-byte
what it is today.

## 4. Rebuild the host once

```bash
cd /Users/ziv/Work/clarity/nanoclaw-v2
pnpm run build      # or: npm run build
```

(If the build script name differs, run whatever produces `dist/index.js`.)

## 5. Install the tunnel + toggle

```bash
cp <this-kit>/com.nanoclaw.onegate-tunnel.plist ~/Library/LaunchAgents/
cp <this-kit>/nanoclaw-proxy.sh /usr/local/bin/nanoclaw-proxy.sh
chmod +x /usr/local/bin/nanoclaw-proxy.sh
```

## 6. Verify baseline (still OneCLI, nothing changed for me yet)

```bash
nanoclaw-proxy.sh status
# expect: mode: onecli / tunnel: down / host: loaded
```

Send me a normal message — I should reply as usual (still on OneCLI).

---

## Switching

**To OneGate:**
```bash
nanoclaw-proxy.sh onegate
```
Then send me a message. If I reply, OneGate is live and proven.

**Back to OneCLI (instant, always works):**
```bash
nanoclaw-proxy.sh onecli
```

**DIRECT (no proxy — last resort if BOTH gateways are off):**
```bash
nanoclaw-proxy.sh direct
```
Direct mode spawns me with no proxy at all and resolves an Anthropic credential
automatically, in this priority order:

1. **Auto-detect (used if present, nothing for you to do):**
   - `CLAUDE_CODE_OAUTH_TOKEN` / `ANTHROPIC_API_KEY` in the host env
   - `~/.claude/.credentials.json` (the Claude Code OAuth token on this Mac)
2. **Override / set it yourself:** `~/.nanoclaw-onegate/direct.env`, one
   `KEY=VALUE` per line. Applied LAST so it wins over auto-detected keys — this
   is how you fix a broken/expired key without touching the host:

   ```
   ANTHROPIC_API_KEY=sk-ant-api03-...
   ```
   (or `CLAUDE_CODE_OAUTH_TOKEN=...`).

If a credential is found anywhere in that chain, I work with zero gateways. If
nothing is found, the container still boots cleanly (never wedged) but I stay
mute until you add a key to direct.env. Nothing to create in advance — only make
direct.env if auto-detect comes up empty or the detected key stops working.

## Rollback / safety

- Default is `onecli`. If the mode file is missing or unreadable, the host
  falls back to OneCLI automatically.
- If OneGate breaks and I go silent, you do NOT need me: just run
  `nanoclaw-proxy.sh onecli` and I'm back on the hosted gateway.
- The tunnel auto-reconnects (KeepAlive) if the SSH drops.
- To fully undo: `nanoclaw-proxy.sh onecli`, then
  `launchctl bootout gui/$(id -u)/com.nanoclaw.onegate-tunnel`, revert the
  container-runner.ts block, rebuild. The `~/.nanoclaw-onegate` dir can stay.

## Notes

- Tunnel: `ssh -N -L 127.0.0.1:18443 -> VM 172.17.0.1:8443` as a launchd job,
  RunAtLoad + KeepAlive. Only runs while in OneGate mode.
- Container reaches the tunnel via `host.docker.internal:18443` (Docker Desktop).
- After the FIRST successful OneGate switch I still need to reconnect Google +
  GitHub through OneGate (one-time connect links). Slack is unaffected.
