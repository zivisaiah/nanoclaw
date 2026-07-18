import { describe, it, expect } from 'vitest';
import { namespaceMessageIdForAgent, platformMessageIdFromAgentId } from './message-id.js';

describe('message-id namespacing', () => {
  const ag = 'ag-1780504303764-4957z7';

  it('round-trips a Telegram composite platform id', () => {
    const platform = '1335216264:2359'; // <chatId>:<messageId>
    const namespaced = namespaceMessageIdForAgent(platform, ag);
    expect(namespaced).toBe('1335216264:2359:ag-1780504303764-4957z7');
    expect(platformMessageIdFromAgentId(namespaced, ag)).toBe(platform);
  });

  it('round-trips a colonless platform id (e.g. a Discord snowflake)', () => {
    const platform = '112233445566778899';
    const namespaced = namespaceMessageIdForAgent(platform, ag);
    expect(platformMessageIdFromAgentId(namespaced, ag)).toBe(platform);
  });

  it('leaves an id without this agent-group suffix untouched', () => {
    // A delivered outbound id is already the raw 2-part platform id — no suffix.
    expect(platformMessageIdFromAgentId('1335216264:2359', ag)).toBe('1335216264:2359');
  });

  it('does not strip a different agent group id that appears mid-string', () => {
    const other = 'ag-9999999999999-zzzzzz';
    expect(platformMessageIdFromAgentId(`1335216264:2359:${other}`, ag)).toBe(
      `1335216264:2359:${other}`,
    );
  });

  it('only strips the exact trailing suffix, not a partial match', () => {
    // agentGroupId is a suffix of a longer trailing segment — must not strip.
    expect(platformMessageIdFromAgentId(`chat:msg:x${ag}`, ag)).toBe(`chat:msg:x${ag}`);
  });
});
