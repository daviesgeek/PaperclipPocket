const MAX_SENT = 500;

/** Polls conversations for new agent-authored comments; does not need Paperclip changes. */
export function createWatcher({
  paperclipURL,
  companyId,
  boardToken,
  state,
  persist,
  deliver,
  fetchImpl = fetch,
  logger = console,
}) {
  const origin = new URL(paperclipURL);
  if (
    origin.protocol !== "https:" &&
    !["localhost", "127.0.0.1"].includes(origin.hostname)
  ) {
    throw new Error(
      "Paperclip must be accessed using HTTPS (except localhost relay-to-server).",
    );
  }

  async function get(path, query = {}) {
    const url = new URL(`/api/${path}`, origin);
    for (const [key, value] of Object.entries(query)) {
      if (value !== undefined && value !== null)
        url.searchParams.set(key, String(value));
    }
    const response = await fetchImpl(url, {
      headers: {
        authorization: `Bearer ${boardToken}`,
        accept: "application/json",
      },
      signal: AbortSignal.timeout(12000),
    });
    if (!response.ok) {
      const reason = (await response.text()).slice(0, 200);
      throw new Error(`Paperclip HTTP ${response.status}: ${reason}`);
    }
    return response.json();
  }

  const isClosed = (status) => ["done", "cancelled"].includes(status);
  // Closed issues stay watched for a day so the closing update still notifies.
  const recentlyUpdated = (issue) =>
    Date.now() - Date.parse(issue.updatedAt ?? "") < 24 * 3600 * 1000;

  async function push(sent, device, key, event) {
    // Recorded before delivery so a crash or lost cursor can never re-push it.
    sent.add(key);
    if (sent.size > MAX_SENT) sent.delete(sent.values().next().value);
    state.sentPushes = [...sent];
    const notificationId = key.startsWith(`${device.token}:`)
      ? key.slice(device.token.length + 1)
      : "unknown";
    try {
      const result = await deliver(device.token, event);
      if (result?.unregister) {
        // Often an APNS_ENVIRONMENT mismatch rather than a dead token; log loudly.
        logger.error(
          `APNs rejected token ${device.token.slice(0, 8)}...: ${result.reason}; removing device`,
        );
        state.devices = state.devices.filter(
          (item) => item.token !== device.token,
        );
      } else {
        logger.log(
          `Pushed ${notificationId} to ${device.token.slice(0, 8)}...`,
        );
      }
    } catch (error) {
      logger.error(
        `APNs delivery failed for ${notificationId} to ${device.token.slice(0, 8)}...:`,
        error,
      );
    }
  }

  async function poll() {
    const chats = await get(`companies/${companyId}/chats`);
    if (!Array.isArray(chats))
      throw new Error("Expected an array from Paperclip /chats");
    let issues = [];
    try {
      const listed = await get(`companies/${companyId}/issues`);
      if (Array.isArray(listed)) {
        const chatIds = new Set(chats.map((chat) => chat.id));
        issues = listed.filter(
          (issue) =>
            !chatIds.has(issue.id) &&
            (!isClosed(issue.status) || recentlyUpdated(issue)),
        );
      }
    } catch (error) {
      logger.error("Could not list issues:", error);
    }
    // Unread-for-token-user set (includes conversations); null means unknown, so fail open.
    let unreadIds = null;
    try {
      const unread = await get(`companies/${companyId}/issues`, {
        unreadForUserId: "me",
      });
      if (Array.isArray(unread)) unreadIds = new Set(unread.map((i) => i.id));
    } catch (error) {
      logger.error("Could not list unread issues:", error);
    }
    const threads = [
      ...chats.map((chat) => ({ ...chat, kind: "chat" })),
      ...issues.map((issue) => ({ ...issue, kind: "issue" })),
    ];
    if (!threads.length) return;
    const roster = await get(`companies/${companyId}/agents`);
    const agentNames = new Map(roster.map((agent) => [agent.id, agent.name]));
    const sent = new Set(state.sentPushes ?? []);

    state.issueStatuses ??= {};
    for (const chat of threads) {
      const previous = state.issueStatuses[chat.id];
      if (chat.kind === "issue" && chat.status) {
        state.issueStatuses[chat.id] = chat.status;
        if (previous && previous !== chat.status) {
          for (const device of state.devices) {
            const key = `${device.token}:status:${chat.id}:${chat.status}`;
            if (sent.has(key)) continue;
            await push(sent, device, key, {
              agentName: chat.title ?? "Issue updated",
              message: `Status changed: ${previous} → ${chat.status}`,
              chatIssueId: chat.id,
              companyId,
            });
          }
          await persist();
        }
      }
      const existing = state.chatCursors[chat.id];
      let cursor = existing?.lastId ?? null;
      // A brand-new watcher watches only messages since devices were registered.
      // This avoids flooding the phone with the entire historical conversation.
      for (let page = 0; page < 10; page++) {
        const comments = await get(`issues/${chat.id}/comments`, {
          order: "asc",
          limit: 500,
          ...(cursor ? { after: cursor } : {}),
        });
        if (!Array.isArray(comments))
          throw new Error("Expected an array of comments");
        if (comments.length === 0) break;
        for (const comment of comments) {
          const alreadyRead = unreadIds !== null && !unreadIds.has(chat.id);
          // Anything not written by a human user (agents, system) notifies.
          const mine = comment.authorUserId && !comment.authorAgentId;
          if (!alreadyRead && !mine && comment.body?.trim()) {
            const agentName = comment.authorAgentId
              ? (agentNames.get(comment.authorAgentId) ?? "Agent")
              : "Paperclip";
            const postedAt = Date.parse(comment.createdAt ?? "");
            const eligible = state.devices.filter(
              (device) =>
                Number.isFinite(postedAt) &&
                postedAt > Date.parse(device.registeredAt) &&
                !sent.has(`${device.token}:${comment.id}`),
            );
            for (const device of eligible) {
              await push(sent, device, `${device.token}:${comment.id}`, {
                agentName:
                  chat.kind === "issue" && chat.title
                    ? `${agentName} on ${chat.title}`
                    : agentName,
                message: comment.body.trim(),
                chatIssueId: chat.id,
                companyId,
              });
            }
          }
          cursor = comment.id;
        }
        state.chatCursors[chat.id] = { lastId: cursor };
        await persist();
        if (comments.length < 500) break;
      }
      if (!(chat.id in state.chatCursors)) {
        state.chatCursors[chat.id] = { lastId: cursor };
        await persist();
      }
    }
  }

  return { poll };
}
