/**
 * Inbound message id namespacing.
 *
 * When one inbound platform message fans out to several agent-group sessions,
 * each session stores it in its own `messages_in` table whose `id` is a PRIMARY
 * KEY. Reusing the raw platform id would collide across sessions, so the router
 * namespaces it as `<platformMessageId>:<agentGroupId>` (see `messageIdForAgent`
 * in router.ts).
 *
 * Channel adapters only understand the raw platform message id, so any id that
 * flows back out to a channel (reactions, edits targeting an inbound message)
 * must have the namespace stripped first. Keep the encode and decode together
 * so the convention can never drift.
 */

export function namespaceMessageIdForAgent(baseId: string, agentGroupId: string): string {
  return `${baseId}:${agentGroupId}`;
}

/**
 * Inverse of {@link namespaceMessageIdForAgent}. Strips the trailing
 * `:<agentGroupId>` and ONLY when it matches exactly, so ids that were never
 * namespaced (e.g. a delivered outbound id that is already the raw platform id)
 * pass through unchanged.
 */
export function platformMessageIdFromAgentId(id: string, agentGroupId: string): string {
  const suffix = `:${agentGroupId}`;
  return id.endsWith(suffix) ? id.slice(0, -suffix.length) : id;
}
