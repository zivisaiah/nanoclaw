#!/usr/bin/env bash
#
# nanoclaw-proxy.sh — deterministic OneCLI <-> OneGate switch for the NanoClaw
# host on this Mac. No LLM involved. Pure bash + launchctl + ssh.
#
#   nanoclaw-proxy.sh onegate   # route Claritas' egress through fleet OneGate
#   nanoclaw-proxy.sh onecli    # route back through hosted OneCLI (default/safe)
#   nanoclaw-proxy.sh direct    # NO proxy — ultimate net if both gateways are off
#   nanoclaw-proxy.sh status    # show current mode, tunnel, host
#
# Switching writes ~/.nanoclaw-onegate/mode, (un)loads the SSH tunnel, and
# restarts the NanoClaw host so the next container spawn picks up the new mode.
#
set -euo pipefail

CFG="$HOME/.nanoclaw-onegate"
MODE_FILE="$CFG/mode"
CONFIG_FILE="$CFG/config.env"
TUNNEL_PLIST="$HOME/Library/LaunchAgents/com.nanoclaw.onegate-tunnel.plist"
TUNNEL_LABEL="com.nanoclaw.onegate-tunnel"
HOST_LABEL="com.nanoclaw-v2-05f4945f"

UID_NUM="$(id -u)"
PORT="18443"
if [ -f "$CONFIG_FILE" ]; then
  p="$(sed -n 's/^[[:space:]]*PROXY_PORT[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$CONFIG_FILE" | head -n1)"
  [ -n "$p" ] && PORT="$p"
fi

usage() { echo "usage: $0 {onegate|onecli|direct|status|--help}"; exit 2; }

help_full() {
  cat <<'EOF'
nanoclaw-proxy.sh — deterministic OneCLI <-> OneGate <-> direct switch

PURPOSE
  Flips how the Claritas agent container reaches Anthropic (and other creds),
  with zero LLM in the loop. Pure bash + launchctl + ssh, so it works even when
  the agent itself is down. Each switch rewrites a mode file, (un)loads the SSH
  tunnel as needed, and restarts the NanoClaw host so the next container spawn
  picks up the new mode. No rebuild is ever needed to switch.

COMMANDS
  onegate   Route egress through the fleet OneGate proxy on the VM.
            Brings up the SSH tunnel (Mac 127.0.0.1:PORT -> VM 172.17.0.1:8443),
            sets mode=onegate, restarts the host. Requires the one-time setup
            (agent token, OneGate CA, VM key, tunnel plist) from SETUP.md.

  onecli    Route egress through the hosted OneCLI gateway (the default, and the
            behavior before any of this existed). Sets mode=onecli, restarts the
            host, tears the tunnel down. This is the always-works fallback: if
            OneGate breaks and the agent goes silent, run this and it is back.

  direct    No proxy at all. Ultimate net for when BOTH gateways are off.
            Resolves an Anthropic credential in priority order and injects it
            straight into the container as env (no proxy, no CA):
              1. Host env  CLAUDE_CODE_OAUTH_TOKEN / ANTHROPIC_API_KEY
              2. ~/.claude/.credentials.json  (Claude Code OAuth token)
              3. ~/.nanoclaw-onegate/direct.env  (KEY=VALUE lines, applied LAST
                 so it overrides auto-detected keys — use it to set a key when
                 none is detected, or to override a broken/expired one)
            If nothing is found the container still boots (never wedged) but the
            agent stays mute until a key is provided.

  status    Print current mode, whether the tunnel port is listening, and
            whether the NanoClaw host launchd job is loaded.

  --help    This text. (-h and help also work.)

FILES  (all under ~/.nanoclaw-onegate)
  mode         current mode: onecli | onegate | direct (missing => onecli)
  config.env   PROXY_PORT=NNNNN (default 18443)
  agent-token  Claritas OneGate agent token (mode 600) — used by onegate
  rootCA.pem   OneGate MITM root CA — mounted into the container in onegate mode
  vm_ed25519   SSH key for the VM tunnel (mode 600)
  direct.env   optional KEY=VALUE overrides for direct mode
  tunnel.log / tunnel.err.log   SSH tunnel launchd logs

SAFETY
  Default mode is onecli. If the mode file is missing or unreadable the host
  falls back to onecli automatically. Switching never depends on the agent.

EXAMPLES
  nanoclaw-proxy.sh status
  nanoclaw-proxy.sh onegate     # try the fleet gateway
  nanoclaw-proxy.sh onecli      # roll back instantly
  nanoclaw-proxy.sh direct      # last resort, uses any detected/dropped key
EOF
}

port_up() { nc -z 127.0.0.1 "$PORT" >/dev/null 2>&1; }

restart_host() {
  launchctl kickstart -k "gui/$UID_NUM/$HOST_LABEL"
}

tunnel_up() {
  if [ ! -f "$TUNNEL_PLIST" ]; then
    echo "ERROR: tunnel plist missing: $TUNNEL_PLIST" >&2
    exit 1
  fi
  # bootstrap is idempotent-ish; ignore "already bootstrapped" then kickstart.
  launchctl bootstrap "gui/$UID_NUM" "$TUNNEL_PLIST" >/dev/null 2>&1 || true
  launchctl enable "gui/$UID_NUM/$TUNNEL_LABEL" >/dev/null 2>&1 || true
  launchctl kickstart "gui/$UID_NUM/$TUNNEL_LABEL" >/dev/null 2>&1 || true
  for _ in $(seq 1 40); do
    port_up && return 0
    sleep 0.5
  done
  echo "ERROR: tunnel did not come up on 127.0.0.1:$PORT (see $CFG/tunnel.err.log)" >&2
  return 1
}

tunnel_down() {
  launchctl bootout "gui/$UID_NUM/$TUNNEL_LABEL" >/dev/null 2>&1 || true
}

case "${1:-}" in
  onegate)
    echo "Bringing up OneGate tunnel..."
    tunnel_up
    echo onegate > "$MODE_FILE"
    echo "Restarting NanoClaw host..."
    restart_host
    echo "OK: mode=ONEGATE, tunnel up on 127.0.0.1:$PORT, host restarted."
    echo "Watch for Claritas to reply. If broken, run: $0 onecli"
    ;;
  onecli)
    echo onecli > "$MODE_FILE"
    echo "Restarting NanoClaw host..."
    restart_host
    tunnel_down
    echo "OK: mode=ONECLI (hosted gateway), host restarted, tunnel down."
    ;;
  direct)
    echo direct > "$MODE_FILE"
    echo "Restarting NanoClaw host..."
    restart_host
    tunnel_down
    echo "OK: mode=DIRECT (no proxy), host restarted, tunnel down."
    echo "Credential resolution order: host env -> ~/.claude/.credentials.json"
    echo "-> $CFG/direct.env (override, wins if present)."
    if [ -f "$CFG/direct.env" ]; then
      echo "direct.env present — it overrides any auto-detected credential."
    elif [ -f "$HOME/.claude/.credentials.json" ]; then
      echo "Found ~/.claude/.credentials.json — its OAuth token will be used."
    else
      echo "NOTE: no override file and no ~/.claude/.credentials.json detected."
      echo "If the host env has no ANTHROPIC_API_KEY/CLAUDE_CODE_OAUTH_TOKEN,"
      echo "create $CFG/direct.env with a working key, then re-run: $0 direct"
    fi
    ;;
  -h|--help|help)
    help_full
    ;;
  status)
    echo "mode:   $(cat "$MODE_FILE" 2>/dev/null || echo 'onecli (default, no mode file)')"
    if port_up; then echo "tunnel: UP (127.0.0.1:$PORT)"; else echo "tunnel: down"; fi
    if launchctl print "gui/$UID_NUM/$HOST_LABEL" >/dev/null 2>&1; then
      echo "host:   loaded ($HOST_LABEL)"
    else
      echo "host:   NOT loaded ($HOST_LABEL)"
    fi
    ;;
  *)
    usage
    ;;
esac
