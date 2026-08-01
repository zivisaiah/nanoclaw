/**
 * Regression guards for this fork's intentional divergences from upstream
 * nanocoai/nanoclaw. See the "Fork divergences" section at the top of CLAUDE.md.
 *
 * WHY THIS FILE EXISTS SEPARATELY, rather than living beside the code it guards:
 *
 * An upstream merge conflicts in `src/container-runner.ts` and
 * `src/channels/chat-sdk-bridge.ts`. Resolving either with "take theirs"
 * compiles, typechecks, and passes the rest of the suite while silently
 * deleting the feature. The tests that would have caught it sit in files that
 * ALSO diverge (`chat-sdk-bridge.test.ts` is ~385 lines off upstream), so the
 * same careless resolution removes the guard and its test together.
 *
 * This path does not exist upstream. A merge therefore produces no conflict
 * here, the file survives untouched, and these tests fail loudly instead.
 * Do not merge these cases into the neighbouring test files — the isolation
 * IS the mechanism.
 */
import fs from 'fs';
import path from 'path';

import { describe, expect, it, vi } from 'vitest';

import type { Adapter } from 'chat';

import { createChatSdkBridge } from './channels/chat-sdk-bridge.js';

vi.mock('./webhook-server.js', () => ({
  registerWebhookAdapter: vi.fn(),
}));

function readSource(...segments: string[]): string {
  return fs.readFileSync(path.join(process.cwd(), ...segments), 'utf-8');
}

function stubAdapter(partial: Partial<Adapter>): Adapter {
  return { name: 'stub', ...partial } as unknown as Adapter;
}

describe('fork divergence: best-effort reactions (behavioral)', () => {
  // Upstream has a bare `await adapter.addReaction(...)`. A platform that
  // rejects an emoji (Telegram's reaction set is a fixed allow-list) then
  // throws out of deliver(), which delivery.ts counts as a delivery failure:
  // three retries, then markDeliveryFailed on a row that is purely cosmetic.
  it('does not throw when the platform rejects the reaction', async () => {
    const bridge = createChatSdkBridge({
      adapter: stubAdapter({
        name: 'telegram',
        addReaction: async () => {
          throw new Error('Bad Request: REACTION_INVALID');
        },
      } as unknown as Partial<Adapter>),
      supportsThreads: false,
    });

    await expect(
      bridge.deliver('telegram:42', null, {
        kind: 'chat-sdk',
        content: { operation: 'reaction', messageId: '123:456', emoji: 'white_check_mark' },
      }),
    ).resolves.toBeUndefined();
  });

  it('still applies a reaction the platform accepts', async () => {
    const applied: string[] = [];
    const bridge = createChatSdkBridge({
      adapter: stubAdapter({
        name: 'telegram',
        addReaction: async (_t: string, _m: string, emoji: string) => {
          applied.push(emoji);
        },
      } as unknown as Partial<Adapter>),
      supportsThreads: false,
    });

    await bridge.deliver('telegram:42', null, {
      kind: 'chat-sdk',
      content: { operation: 'reaction', messageId: '123:456', emoji: 'eyes' },
    });

    expect(applied).toEqual(['eyes']);
  });
});

describe('fork divergence: OneGate proxy switch (structural)', () => {
  // Driving the real buildContainerArgs needs a live gateway and container
  // runtime, so these guard the wiring structurally — the same approach
  // container-runner.test.ts already takes for its ordering invariant.

  it('keeps the three-way proxy mode switch', () => {
    const src = readSource('src', 'container-runner.ts');
    expect(src).toContain('readProxyMode');
    expect(src).toContain('applyOneGateContainerConfig');
    expect(src).toContain('applyDirectContainerConfig');
    // Upstream's OneCLI path must survive as the fallback branch.
    expect(src).toContain('onecli.applyContainerConfig');
  });

  it('applies the proxy gateway after the volume mounts', () => {
    // A credential stub nested inside one of our RW mounts has to land later
    // in the docker args than its parent, or the parent bind shadows it.
    const src = readSource('src', 'container-runner.ts');
    const mountsLoop = src.indexOf('for (const mount of mounts)');
    const proxySwitch = src.indexOf('const proxyMode = readProxyMode()');
    expect(mountsLoop).toBeGreaterThan(-1);
    expect(proxySwitch).toBeGreaterThan(-1);
    expect(proxySwitch).toBeGreaterThan(mountsLoop);
  });

  it('calls hostGatewayArgs exactly once', () => {
    // It belongs in the else-branch of the egress-lockdown check. A second
    // unconditional call double-pushes the flag when lockdown is off, and
    // defeats lockdown entirely when it is on.
    const src = readSource('src', 'container-runner.ts');
    const calls = src.match(/args\.push\(\.\.\.hostGatewayArgs\(\)\)/g) ?? [];
    expect(calls).toHaveLength(1);
  });

  it('keeps the fork-only proxy module', () => {
    const src = readSource('src', 'onegate-proxy.ts');
    expect(src).toContain('export function readProxyMode');
    expect(src).toContain('export function applyOneGateContainerConfig');
    expect(src).toContain('export function applyDirectContainerConfig');
  });
});
