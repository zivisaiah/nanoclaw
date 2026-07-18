/**
 * OneGate proxy gateway — deterministic, file-flagged alternative to OneCLI.
 *
 * Mode is read fresh from ~/.nanoclaw-onegate/mode on EVERY container spawn, so
 * switching between OneCLI and OneGate never needs a rebuild. The toggle script
 * (nanoclaw-proxy.sh) just rewrites that file, (un)loads the SSH tunnel, and
 * restarts the host process. No LLM in the loop.
 *
 * When mode === 'onegate', applyOneGateContainerConfig() appends the proxy env
 * + CA mount to the docker run args, mirroring what onecli.applyContainerConfig
 * does, but pointing at a local SSH forward to the fleet OneGate instead of the
 * hosted OneCLI gateway.
 *
 * Drop this file at: src/onegate-proxy.ts
 */
import fs from 'fs';
import os from 'os';
import path from 'path';

import { log } from './log.js';

const CFG_DIR = path.join(os.homedir(), '.nanoclaw-onegate');
const MODE_FILE = path.join(CFG_DIR, 'mode');
const TOKEN_FILE = path.join(CFG_DIR, 'agent-token');
const CONFIG_FILE = path.join(CFG_DIR, 'config.env');
const GATE_TOKEN_FILE = path.join(CFG_DIR, 'gate-token');
const DIRECT_ENV_FILE = path.join(CFG_DIR, 'direct.env');
const CA_HOST_PATH = path.join(CFG_DIR, 'rootCA.pem');
const CA_CONTAINER_PATH = '/etc/onegate/rootCA.pem';

// Format-valid but deliberately-fake Claude Code OAuth token. OneGate rewrites
// the real upstream Authorization header at the edge, so the client only needs
// a token that satisfies the SDK's local presence/format check — a real secret
// must never sit in the container env. Same principle OneCLI uses. 108 chars to
// match the real token length.
const PLACEHOLDER_GATE_TOKEN = 'sk-ant-oat01-onegate-placeholder-'.padEnd(108, '0');

export type ProxyMode = 'onecli' | 'onegate' | 'direct';

/** Fail-safe: any error or unrecognized value -> 'onecli' (the known-good path). */
export function readProxyMode(): ProxyMode {
  try {
    const v = fs.readFileSync(MODE_FILE, 'utf8').trim().toLowerCase();
    if (v === 'onegate') return 'onegate';
    if (v === 'direct') return 'direct';
    return 'onecli';
  } catch {
    return 'onecli';
  }
}

function readConfigPort(): string {
  try {
    const txt = fs.readFileSync(CONFIG_FILE, 'utf8');
    const m = txt.match(/^\s*PROXY_PORT\s*=\s*(\d+)\s*$/m);
    if (m) return m[1];
  } catch {
    /* fall through to default */
  }
  return '18443';
}

/**
 * Resolve a Claude Code OAuth token for the SDK's own client login gate.
 *
 * In onegate mode OneGate overwrites the real upstream Authorization header, so
 * this value is NOT the credential that talks to Anthropic — it only has to be
 * present and valid-format so the Claude Code SDK will proceed past its local
 * login check and actually issue POST /v1/messages. Without it the SDK stops at
 * a GET /v1/models probe and never calls the model (the exact failure we hit).
 *
 * Default is the built-in PLACEHOLDER — no real secret in the container. An
 * explicit override is honored only if you deliberately drop a real token at
 * ~/.nanoclaw-onegate/gate-token or set CLAUDE_CODE_OAUTH_TOKEN in the host env
 * (escape hatch; not used in normal operation). Never returns undefined, so the
 * SDK gate is always satisfied. Value is never logged.
 */
function resolveClaudeGateToken(): { token: string; source: string } {
  try {
    const fileTok = fs.readFileSync(GATE_TOKEN_FILE, 'utf8').trim();
    if (fileTok) return { token: fileTok, source: 'gate-token-file' };
  } catch {
    /* no gate-token file — fall through */
  }
  const envTok = process.env['CLAUDE_CODE_OAUTH_TOKEN'];
  if (envTok && envTok.trim()) return { token: envTok.trim(), source: 'host-env' };
  return { token: PLACEHOLDER_GATE_TOKEN, source: 'placeholder' };
}

/**
 * Append OneGate proxy env + CA mount to `args`. Throws if the token or CA is
 * missing so we never silently spawn without credentials (parity with the
 * OneCLI path's hard-fail). The agent token is never logged.
 */
export function applyOneGateContainerConfig(
  args: string[],
  opts: { agent?: string; containerName: string },
): void {
  const token = fs.readFileSync(TOKEN_FILE, 'utf8').trim();
  if (!token) throw new Error('OneGate agent token empty — refusing to spawn');
  if (!fs.existsSync(CA_HOST_PATH)) {
    throw new Error(`OneGate CA missing at ${CA_HOST_PATH} — refusing to spawn`);
  }
  const port = readConfigPort();

  // The container reaches the Mac host (where the SSH forward listens) via
  // host.docker.internal; the forward tunnels on to the VM's 172.17.0.1:8443.
  const proxyUrl = `http://agent:${token}@host.docker.internal:${port}`;

  // Mount the OneGate root CA read-only. It is a public CA cert, not a secret.
  args.push('-v', `${CA_HOST_PATH}:${CA_CONTAINER_PATH}:ro`);

  // Every TLS connection terminates at the OneGate MITM (OneGate-signed leaves),
  // so the OneGate CA is the correct trust root for SSL_CERT_FILE / DENO_CERT and
  // additive for Node via NODE_EXTRA_CA_CERTS.
  const env: Record<string, string> = {
    HTTPS_PROXY: proxyUrl,
    HTTP_PROXY: proxyUrl,
    https_proxy: proxyUrl,
    http_proxy: proxyUrl,
    NO_PROXY: 'localhost,127.0.0.1,host.docker.internal,::1',
    no_proxy: 'localhost,127.0.0.1,host.docker.internal,::1',
    NODE_EXTRA_CA_CERTS: CA_CONTAINER_PATH,
    SSL_CERT_FILE: CA_CONTAINER_PATH,
    DENO_CERT: CA_CONTAINER_PATH,
    NODE_USE_ENV_PROXY: '1',
    GIT_HTTP_PROXY_AUTHMETHOD: 'basic',
  };

  // The Claude Code SDK requires a valid-format CLAUDE_CODE_OAUTH_TOKEN to pass
  // its own client login gate before it will call /v1/messages. OneGate replaces
  // the real upstream credential at the edge, so this token is only the local
  // gate key. In OneCLI mode the OneCLI SDK injects this for us; on the OneGate
  // path we must supply it ourselves or the SDK stalls at GET /v1/models.
  const gate = resolveClaudeGateToken();
  env['CLAUDE_CODE_OAUTH_TOKEN'] = gate.token;

  for (const [k, v] of Object.entries(env)) args.push('-e', `${k}=${v}`);

  log.info('OneGate proxy env applied', {
    containerName: opts.containerName,
    agent: opts.agent,
    port,
    gateSource: gate.source,
  });
}

/**
 * DIRECT mode: no proxy at all. Ultimate safety net for when BOTH OneCLI and
 * OneGate are down. Resolves an Anthropic credential in priority order and
 * injects it straight into the container as env (no proxy, no CA):
 *
 *   1. Auto-detect existing credentials (used automatically if present):
 *        - CLAUDE_CODE_OAUTH_TOKEN / ANTHROPIC_API_KEY in the host env
 *        - ~/.claude/.credentials.json (Claude Code OAuth access token)
 *   2. ~/.nanoclaw-onegate/direct.env — user-set / OVERRIDE. Applied last so it
 *      wins over anything auto-detected, letting you fix a broken/expired key
 *      without touching the host.
 *
 * If nothing is found, the container still spawns (never wedged) but the agent
 * has no LLM credential until one is provided. Secret VALUES are never logged,
 * only which source each key came from.
 */
export function applyDirectContainerConfig(
  args: string[],
  opts: { containerName: string },
): void {
  const injected: Record<string, string> = {};
  const sources: Record<string, string> = {};

  // 1a. Host env.
  for (const k of ['CLAUDE_CODE_OAUTH_TOKEN', 'ANTHROPIC_API_KEY']) {
    const v = process.env[k];
    if (v && v.trim()) {
      injected[k] = v.trim();
      sources[k] = 'host-env';
    }
  }

  // 1b. Claude Code credential store (OAuth access token).
  try {
    const credPath = path.join(os.homedir(), '.claude', '.credentials.json');
    const j = JSON.parse(fs.readFileSync(credPath, 'utf8'));
    const tok: string | undefined = j?.claudeAiOauth?.accessToken;
    if (tok && tok.trim() && !injected['CLAUDE_CODE_OAUTH_TOKEN']) {
      injected['CLAUDE_CODE_OAUTH_TOKEN'] = tok.trim();
      sources['CLAUDE_CODE_OAUTH_TOKEN'] = 'claude-credentials';
    }
  } catch {
    /* no credential store — fine */
  }

  // 2. Explicit override file (highest priority).
  try {
    const txt = fs.readFileSync(DIRECT_ENV_FILE, 'utf8');
    for (const raw of txt.split('\n')) {
      const line = raw.trim();
      if (!line || line.startsWith('#')) continue;
      const eq = line.indexOf('=');
      if (eq <= 0) continue;
      const key = line.slice(0, eq).trim();
      const val = line.slice(eq + 1).trim();
      if (!key) continue;
      injected[key] = val;
      sources[key] = 'direct.env';
    }
  } catch {
    /* no override file — fine */
  }

  for (const [k, v] of Object.entries(injected)) args.push('-e', `${k}=${v}`);

  if (Object.keys(injected).length === 0) {
    log.warn('DIRECT mode: no proxy AND no credential found', {
      containerName: opts.containerName,
    });
  } else {
    log.warn('DIRECT mode: no proxy, direct credential applied', {
      containerName: opts.containerName,
      sources,
    });
  }
}
