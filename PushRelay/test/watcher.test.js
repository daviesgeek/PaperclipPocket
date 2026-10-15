import test from "node:test";
import assert from "node:assert/strict";
import { createWatcher } from "../watcher.js";

const TOKEN = "1".repeat(64);
const registration = "2026-10-14T10:00:00.000Z";
const old = {
  id: "c1",
  body: "Old reply",
  authorAgentId: "a1",
  createdAt: "2026-10-14T09:00:00.000Z",
};
const newReply = {
  id: "c3",
  body: "New reply",
  authorAgentId: "a1",
  createdAt: "2026-10-14T11:00:00.000Z",
};
const human = {
  id: "c2",
  body: "Question",
  authorAgentId: null,
  authorUserId: "human",
  createdAt: "2026-10-14T10:30:00.000Z",
};

test("notifies only new agent replies, once, with correct deep-link ID", async () => {
  let comments = [old, human];
  let saved = 0;
  const delivered = [];
  const logMessages = [];
  const state = {
    devices: [{ token: TOKEN, registeredAt: registration }],
    chatCursors: {},
  };
  const fakeFetch = async (url) => {
    const path = new URL(url).pathname;
    if (path.endsWith("/chats")) return Response.json([{ id: "chat-123" }]);
    if (path.endsWith("/agents"))
      return Response.json([{ id: "a1", name: "Builder" }]);
    if (path.endsWith("/issues"))
      return Response.json(
        new URL(url).searchParams.has("unreadForUserId")
          ? [{ id: "chat-123" }]
          : [],
      );
    const after = new URL(url).searchParams.get("after");
    const start = after
      ? comments.findIndex((comment) => comment.id === after) + 1
      : 0;
    return Response.json(comments.slice(start));
  };
  const watcher = createWatcher({
    paperclipURL: "https://paperclip.example.com",
    companyId: "co",
    boardToken: "key",
    state,
    persist: async () => {
      saved++;
    },
    deliver: async (token, event) => {
      delivered.push({ token, ...event });
      return { success: true };
    },
    logger: {
      log: (...args) => logMessages.push(args.join(" ")),
      error: (...args) => logMessages.push(args.join(" ")),
    },
    fetchImpl: fakeFetch,
  });
  await watcher.poll();
  assert.equal(delivered.length, 0);
  assert.equal(state.chatCursors["chat-123"].lastId, "c2");
  comments.push(newReply);
  await watcher.poll();
  await watcher.poll();
  assert.equal(saved > 0, true);
  assert.deepEqual(delivered, [
    {
      token: TOKEN,
      agentName: "Builder",
      message: "New reply",
      chatIssueId: "chat-123",
      companyId: "co",
    },
  ]);
  assert.equal(
    logMessages.some((message) => message.includes(TOKEN)),
    false,
  );
  assert.ok(
    logMessages.some((message) => message.includes(`${TOKEN.slice(0, 8)}...`)),
  );
});

test("does not log the full device token when delivery fails", async () => {
  const logMessages = [];
  const state = {
    devices: [{ token: TOKEN, registeredAt: registration }],
    chatCursors: {},
  };
  const watcher = createWatcher({
    paperclipURL: "https://paperclip.example.com",
    companyId: "co",
    boardToken: "key",
    state,
    persist: async () => {},
    deliver: async () => {
      throw new Error("APNs unavailable");
    },
    logger: {
      log: (...args) => logMessages.push(args.join(" ")),
      error: (...args) => logMessages.push(args.join(" ")),
    },
    fetchImpl: async (url) => {
      if (url.pathname.endsWith("/chats"))
        return Response.json([{ id: "chat-1" }]);
      if (url.pathname.endsWith("/agents"))
        return Response.json([{ id: "a1", name: "Builder" }]);
      if (url.pathname.endsWith("/issues"))
        return Response.json(
          url.searchParams.has("unreadForUserId") ? [{ id: "chat-1" }] : [],
        );
      return Response.json([newReply]);
    },
  });

  await watcher.poll();

  assert.equal(
    logMessages.some((message) => message.includes(TOKEN)),
    false,
  );
  assert.ok(
    logMessages.some((message) => message.includes("APNs delivery failed")),
  );
});

test("notifies replies in a new conversation even if it was created between polls", async () => {
  const delivered = [];
  const state = {
    devices: [{ token: TOKEN, registeredAt: registration }],
    chatCursors: {},
  };
  const watcher = createWatcher({
    paperclipURL: "https://paperclip.example.com",
    companyId: "co",
    boardToken: "key",
    state,
    persist: async () => {},
    deliver: async (_, event) => {
      delivered.push(event);
      return { success: true };
    },
    fetchImpl: async (url) => {
      if (url.pathname.endsWith("/chats"))
        return Response.json([{ id: "new-chat" }]);
      if (url.pathname.endsWith("/agents"))
        return Response.json([{ id: "a1", name: "Builder" }]);
      if (url.pathname.endsWith("/issues"))
        return Response.json(
          url.searchParams.has("unreadForUserId") ? [{ id: "new-chat" }] : [],
        );
      return Response.json([newReply]);
    },
  });
  await watcher.poll();
  assert.equal(delivered.length, 1);
});

test("does not push for threads the user has already read", async () => {
  const delivered = [];
  const state = {
    devices: [{ token: TOKEN, registeredAt: registration }],
    chatCursors: {},
  };
  const watcher = createWatcher({
    paperclipURL: "https://paperclip.example.com",
    companyId: "co",
    boardToken: "key",
    state,
    persist: async () => {},
    deliver: async (_, event) => {
      delivered.push(event);
      return { success: true };
    },
    fetchImpl: async (url) => {
      if (url.pathname.endsWith("/chats"))
        return Response.json([{ id: "read-chat" }]);
      if (url.pathname.endsWith("/agents"))
        return Response.json([{ id: "a1", name: "Builder" }]);
      if (url.pathname.endsWith("/issues")) return Response.json([]);
      return Response.json([newReply]);
    },
  });
  await watcher.poll();
  assert.equal(delivered.length, 0);
  assert.equal(state.chatCursors["read-chat"].lastId, "c3");
});

test("does not re-push a comment after the cursor is lost", async () => {
  const delivered = [];
  const state = {
    devices: [{ token: TOKEN, registeredAt: registration }],
    chatCursors: {},
  };
  const watcher = createWatcher({
    paperclipURL: "https://paperclip.example.com",
    companyId: "co",
    boardToken: "key",
    state,
    persist: async () => {},
    deliver: async (_, event) => {
      delivered.push(event);
      return { success: true };
    },
    fetchImpl: async (url) => {
      if (url.pathname.endsWith("/chats"))
        return Response.json([{ id: "chat-1" }]);
      if (url.pathname.endsWith("/agents"))
        return Response.json([{ id: "a1", name: "Builder" }]);
      if (url.pathname.endsWith("/issues"))
        return Response.json(
          url.searchParams.has("unreadForUserId") ? [{ id: "chat-1" }] : [],
        );
      return Response.json([newReply]);
    },
  });
  await watcher.poll();
  state.chatCursors = {};
  await watcher.poll();
  assert.equal(delivered.length, 1);
});
