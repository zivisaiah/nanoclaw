#!/usr/bin/env bash
#
# nanoclaw_control.sh — Start, stop, or restart the NanoClaw launchd service.
#
# Usage:
#   ./nanoclaw_control.sh start
#   ./nanoclaw_control.sh stop
#   ./nanoclaw_control.sh restart
#   ./nanoclaw_control.sh status

set -euo pipefail

# ─── Paths ───────────────────────────────────────────────────────────────────
# This script lives in the repo root, alongside data/ and scripts/.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$SCRIPT_DIR"

# Query a SQLite DB via the in-tree wrapper (no sqlite3 binary dependency; same
# pipe-separated output as `sqlite3 -list`). Usage: q <db-path> "<sql>"
# Never aborts the caller — returns empty on any failure.
q() {
  ( cd "$REPO_DIR" && pnpm exec tsx scripts/q.ts "$1" "$2" 2>/dev/null ) || true
}

# Output format for reporting commands: "text" (default) or "json" (--json).
OUT="text"
# Unit-separator field delimiter — survives pipes/quotes/spaces in task text.
US=$'\x1f'

# Convert US-delimited stdin lines into a JSON array of objects (keys comma-list).
# Usage: printf '%s' "$body" | _json_array "key1,key2,..."
_json_array() {
  KEYS="$1" node -e '
    const fs=require("fs"), US="\x1f";
    const keys=(process.env.KEYS||"").split(",");
    const rows=fs.readFileSync(0,"utf8").split("\n").filter(Boolean).map(l=>{
      const f=l.split(US), o={}; keys.forEach((k,i)=>o[k]=(f[i]&&f[i].length)?f[i]:null); return o;
    });
    process.stdout.write(JSON.stringify(rows,null,2)+"\n");
  '
}

# ─── Discover plist ────────────────────────────────────────────────────────────

LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"

find_plist() {
  local plist
  plist=$(ls "$LAUNCH_AGENTS_DIR"/com.nanoclaw*.plist 2>/dev/null | head -1)
  echo "$plist"
}

PLIST=$(find_plist)

if [[ -z "$PLIST" ]]; then
  echo "Error: no NanoClaw launchd plist found in $LAUNCH_AGENTS_DIR" >&2
  echo "       Run the NanoClaw setup first: bash nanoclaw.sh" >&2
  exit 1
fi

LABEL=$(defaults read "$PLIST" Label 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Print :Label" "$PLIST" 2>/dev/null \
  || grep -A1 '<key>Label</key>' "$PLIST" | tail -1 | sed 's|.*<string>\(.*\)</string>.*|\1|') \
  || true

if [[ -z "${LABEL:-}" ]]; then
  echo "Error: could not determine Label from $PLIST" >&2
  exit 1
fi

# ─── Helpers ───────────────────────────────────────────────────────────────────

svc_loaded() {
  launchctl list "$LABEL" &>/dev/null
}

svc_stop() {
  if svc_loaded; then
    echo "Stopping $LABEL…"
    launchctl unload "$PLIST"
    echo "Stopped."
  else
    echo "$LABEL is not running."
  fi
}

svc_start() {
  if svc_loaded; then
    echo "$LABEL is already running."
  else
    echo "Starting $LABEL…"
    launchctl load "$PLIST"
    echo "Started."
  fi
}

svc_status() {
  if svc_loaded; then
    local pid
    pid=$(launchctl list "$LABEL" 2>/dev/null | awk '/"PID"/ {gsub(/[^0-9]/, "", $3); print $3}')
    if [[ -n "$pid" ]]; then
      echo "$LABEL is running (PID $pid)"
    else
      echo "$LABEL is loaded (no PID yet — may be starting)"
    fi
  else
    echo "$LABEL is stopped"
  fi
}

# ─── Task / cron reporting ───────────────────────────────────────────────────

# Resolve an agent-group id (from a session dir path) to its display name.
ag_name() {
  local ag="$1" name
  name=$(q "data/v2.db" "SELECT name FROM agent_groups WHERE id='$ag'")
  echo "${name:-$ag}"
}

# List recurring scheduled tasks (rows with a cron recurrence) across all sessions.
svc_crons() {
  set +e
  local body="" db ag name out
  for db in "$REPO_DIR"/data/v2-sessions/*/*/inbound.db; do
    [[ -e "$db" ]] || continue
    ag=$(basename "$(dirname "$(dirname "$db")")")
    name=$(ag_name "$ag")
    out=$(q "$db" "SELECT recurrence||char(31)||COALESCE(datetime(process_after),'?')||char(31)||status||char(31)||substr(replace(replace(COALESCE(json_extract(content,'\$.prompt'),content),char(10),' '),char(13),' '),1,104) FROM messages_in WHERE recurrence IS NOT NULL AND recurrence!='' AND status='pending' ORDER BY process_after")
    [[ -n "$out" ]] && body+=$(printf '%s' "$out" | sed "s#^#${name}${US}#")$'\n'
  done
  if [[ "$OUT" == json ]]; then
    printf '%s' "$body" | _json_array "agent,cron,next_run_utc,status,task"
    return
  fi
  echo "Recurring scheduled tasks (cron jobs)"
  echo
  if [[ -z "${body//[[:space:]]/}" ]]; then
    echo "  (no recurring tasks scheduled)"
  else
    { printf 'AGENT%sCRON%sNEXT RUN (UTC)%sSTATUS%sTASK\n' "$US" "$US" "$US" "$US"; printf '%s' "$body"; } | column -t -s "$US"
  fi
}

# List ad-hoc / in-flight work: running containers + pending non-recurring tasks.
svc_tasks() {
  set +e
  local body="" db ag name out
  for db in "$REPO_DIR"/data/v2-sessions/*/*/inbound.db; do
    [[ -e "$db" ]] || continue
    ag=$(basename "$(dirname "$(dirname "$db")")")
    name=$(ag_name "$ag")
    out=$(q "$db" "SELECT status||char(31)||COALESCE(datetime(process_after),'now')||char(31)||substr(replace(replace(json_extract(content,'\$.prompt'),char(10),' '),char(13),' '),1,104) FROM messages_in WHERE status='pending' AND (recurrence IS NULL OR recurrence='') AND json_extract(content,'\$.prompt') IS NOT NULL ORDER BY process_after")
    [[ -n "$out" ]] && body+=$(printf '%s' "$out" | sed "s#^#${name}${US}#")$'\n'
  done
  if [[ "$OUT" == json ]]; then
    local cnames; cnames=$(docker ps --filter "name=nanoclaw-v2" --format "{{.Names}}${US}{{.Status}}" 2>/dev/null)
    CONTAINERS="$cnames" TASKS="$body" node -e '
      const US="\x1f";
      const parse=(s,keys)=>(s||"").split("\n").filter(Boolean).map(l=>{const f=l.split(US),o={};keys.forEach((k,i)=>o[k]=(f[i]&&f[i].length)?f[i]:null);return o;});
      const out={containers:parse(process.env.CONTAINERS,["name","status"]),pending_tasks:parse(process.env.TASKS,["agent","status","due_utc","task"])};
      process.stdout.write(JSON.stringify(out,null,2)+"\n");
    '
    return
  fi
  echo "Running / queued tasks"
  echo
  echo "Active agent containers:"
  local c; c=$(docker ps --filter "name=nanoclaw-v2" --format '  {{.Names}}  ({{.Status}})' 2>/dev/null)
  [[ -n "$c" ]] && echo "$c" || echo "  (none running — idle)"
  echo
  echo "Pending ad-hoc / one-off tasks (for the recurring schedule, run: $0 crons):"
  if [[ -z "${body//[[:space:]]/}" ]]; then
    echo "  (no ad-hoc tasks queued)"
  else
    { printf 'AGENT%sSTATUS%sDUE (UTC)%sTASK\n' "$US" "$US" "$US"; printf '%s' "$body"; } | column -t -s "$US"
  fi
}

# ─── Health check ──────────────────────────────────────────────────────────────

HEALTH_ISSUES=0
HEALTH_FAIL=0
HC_RECORDS=""
if [[ -t 1 ]]; then C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_FAIL=$'\033[31m'; C_OFF=$'\033[0m'; else C_OK=""; C_WARN=""; C_FAIL=""; C_OFF=""; fi

hc() { # hc OK|WARN|FAIL "label" ["detail"]
  local st="$1" label="$2" detail="${3:-}"
  HC_RECORDS+="${st}${US}${label}${US}${detail}"$'\n'
  case "$st" in
    WARN) HEALTH_ISSUES=$((HEALTH_ISSUES+1)) ;;
    FAIL) HEALTH_ISSUES=$((HEALTH_ISSUES+1)); HEALTH_FAIL=$((HEALTH_FAIL+1)) ;;
  esac
  [[ "$OUT" == json ]] && return 0
  case "$st" in
    OK)   printf "  ${C_OK}[ OK ]${C_OFF} %s\n" "$label" ;;
    WARN) printf "  ${C_WARN}[WARN]${C_OFF} %s — %s\n" "$label" "$detail" ;;
    FAIL) printf "  ${C_FAIL}[FAIL]${C_OFF} %s — %s\n" "$label" "$detail" ;;
  esac
}

svc_health() {
  set +e
  [[ "$OUT" != json ]] && { echo "NanoClaw health scan"; echo; }
  local now; now=$(date +%s)

  # 1. launchd service
  if svc_loaded; then
    local pid; pid=$(launchctl list "$LABEL" 2>/dev/null | awk '/"PID"/ {gsub(/[^0-9]/,"",$3); print $3}')
    [[ -n "$pid" ]] && hc OK "launchd service ($LABEL, PID $pid)" || hc WARN "launchd service loaded, no PID" "may be starting/crash-looping"
  else
    hc FAIL "launchd service" "$LABEL not loaded — run: $0 start"
  fi

  # 2. docker daemon
  docker info &>/dev/null && hc OK "docker daemon" || hc FAIL "docker daemon" "not responding — start Docker"

  # 3. central DB integrity
  local ic; ic=$(q "data/v2.db" "PRAGMA integrity_check" | head -1)
  [[ "$ic" == "ok" ]] && hc OK "central DB (data/v2.db) integrity" || hc FAIL "central DB integrity" "${ic:-unreadable}"

  # 4. host disk
  local freeg; freeg=$(df -g "$REPO_DIR" 2>/dev/null | awk 'NR==2{print $4}')
  if [[ -n "$freeg" ]]; then
    (( freeg < 20 )) && hc WARN "host disk" "${freeg}G free (<20G — clean up)" || hc OK "host disk (${freeg}G free)"
  fi

  # 5. OneCLI gateway (agents 401 without it)
  local oc; oc=$(docker ps --filter "name=^onecli$" --format '{{.Status}}' 2>/dev/null)
  if [[ -z "$oc" ]]; then hc WARN "OneCLI gateway" "container not running (agents may 401)"
  elif echo "$oc" | grep -qi healthy; then hc OK "OneCLI gateway ($oc)"
  else hc WARN "OneCLI gateway" "$oc"; fi

  # 6. agent containers: thrash + zombies + heartbeat freshness
  local containers; containers=$(docker ps --filter "name=nanoclaw-v2" --format '{{.Names}}' 2>/dev/null)
  if [[ -z "$containers" ]]; then
    hc OK "agent containers (none running — idle)"
  else
    local cn up thrash z folder agid hb age
    while read -r cn; do
      [[ -z "$cn" ]] && continue
      up=$(docker ps --filter "name=^${cn}$" --format '{{.Status}}' 2>/dev/null)
      thrash=$(docker logs --tail 300 "$cn" 2>&1 | grep -c "Autocompact is thrashing" || true)
      if (( thrash > 0 )); then hc FAIL "container $cn" "autocompact THRASHING — send /clear (see memory)"; else hc OK "container $cn ($up)"; fi
      z=$(docker exec "$cn" sh -c 'ps -eo args 2>/dev/null | grep -c "[d]efunct"' 2>/dev/null || echo 0)
      (( z > 3 )) && hc WARN "container $cn zombies" "$z defunct processes (crashed browser tool?)"
      # heartbeat for this container's session
      folder=$(echo "$cn" | sed -E 's/^nanoclaw-v2-(.*)-[0-9]+$/\1/')
      agid=$(q "data/v2.db" "SELECT s.agent_group_id FROM sessions s JOIN agent_groups g ON g.id=s.agent_group_id WHERE g.folder='$folder' LIMIT 1")
      hb=$(ls "$REPO_DIR"/data/v2-sessions/"$agid"/*/.heartbeat 2>/dev/null | head -1)
      if [[ -n "$hb" ]]; then
        age=$(( now - $(stat -f %m "$hb") ))
        (( age > 180 )) && hc WARN "container $cn heartbeat" "stale ${age}s (long turn or wedged)" || hc OK "container $cn heartbeat (${age}s fresh)"
      fi
    done <<< "$containers"
  fi

  # 7. recent permanent delivery failures
  local delerr; delerr=$(tail -300 "$REPO_DIR/logs/nanoclaw.error.log" 2>/dev/null | grep -c "delivery failed permanently" || true)
  (( delerr > 0 )) && hc WARN "message delivery" "$delerr permanent failure(s) in recent error log" || hc OK "message delivery (no recent permanent failures)"

  # 8. overdue scheduled tasks (scheduler stuck?)
  local overdue=0 db n
  for db in "$REPO_DIR"/data/v2-sessions/*/*/inbound.db; do
    [[ -e "$db" ]] || continue
    n=$(q "$db" "SELECT COUNT(*) FROM messages_in WHERE status='pending' AND process_after IS NOT NULL AND datetime(process_after) < datetime('now','-10 minutes')" | tr -dc '0-9')
    overdue=$(( overdue + ${n:-0} ))
  done
  (( overdue > 0 )) && hc WARN "scheduler" "$overdue task(s) overdue >10min (host-sweep stuck?)" || hc OK "scheduler (no overdue tasks)"

  if [[ "$OUT" == json ]]; then
    HC="$HC_RECORDS" node -e '
      const US="\x1f";
      const checks=(process.env.HC||"").split("\n").filter(Boolean).map(l=>{const [status,label,detail]=l.split(US);return {status,label,detail:(detail&&detail.length)?detail:null};});
      const fails=checks.filter(c=>c.status==="FAIL").length, warns=checks.filter(c=>c.status==="WARN").length;
      process.stdout.write(JSON.stringify({overall:fails?"fail":(warns?"warn":"ok"),issues:warns+fails,fails,warns,checks},null,2)+"\n");
    '
  else
    echo
    if (( HEALTH_ISSUES == 0 )); then
      echo "${C_OK}Overall: HEALTHY — all checks passed.${C_OFF}"
    else
      echo "${C_WARN}Overall: $HEALTH_ISSUES issue(s) found (see WARN/FAIL above).${C_OFF}"
    fi
  fi
}

# ─── Main ──────────────────────────────────────────────────────────────────────

CMD="${1:-}"

# --json (anywhere) switches tasks/crons/health to machine-readable output.
for _a in "$@"; do [[ "$_a" == "--json" ]] && OUT="json"; done

case "$CMD" in
  start)
    svc_start
    ;;
  stop)
    svc_stop
    ;;
  restart)
    svc_stop
    sleep 1
    svc_start
    ;;
  status)
    svc_status
    ;;
  tasks)
    svc_tasks
    ;;
  crons)
    svc_crons
    ;;
  health)
    svc_health
    # exit non-zero only on a hard FAIL, so WARN stays advisory (monitoring-friendly)
    (( HEALTH_FAIL > 0 )) && exit 2 || exit 0
    ;;
  *)
    echo "Usage: $0 {start|stop|restart|status|tasks|crons|health} [--json]"
    echo
    echo "  start|stop|restart   manage the launchd service"
    echo "  status               is the service running?"
    echo "  tasks   [--json]     running containers + pending ad-hoc/one-off tasks"
    echo "  crons   [--json]     recurring scheduled tasks (cron jobs)"
    echo "  health  [--json]     scan every component; exit 2 on hard FAIL"
    exit 1
    ;;
esac
