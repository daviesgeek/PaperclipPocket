import { createServer } from "node:http";
import { createHash, timingSafeEqual } from "node:crypto";
import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { APNsClient } from "./apns.js";
import { createWatcher } from "./watcher.js";

const required = [
  "PAPERCLIP_URL",
  "PAPERCLIP_COMPANY_ID",
  "PAPERCLIP_BOARD_TOKEN",
  "PUSH_RELAY_SECRET",
  "APNS_TEAM_ID",
  "APNS_KEY_ID",
  "APNS_BUNDLE_ID",
  "APNS_PRIVATE_KEY_PATH",
];
for (const name of required) {
  if (!process.env[name])
    throw new Error(`Missing environment variable ${name}`);
}
const companyId = process.env.PAPERCLIP_COMPANY_ID;
const dataFile = resolve(process.env.PUSH_DATA_FILE ?? "./data/state.json");
const secretHash = createHash("sha256")
  .update(process.env.PUSH_RELAY_SECRET)
  .digest();
const apns = new APNsClient({
  teamId: process.env.APNS_TEAM_ID,
  keyId: process.env.APNS_KEY_ID,
  bundleId: process.env.APNS_BUNDLE_ID,
  keyPath: process.env.APNS_PRIVATE_KEY_PATH,
  environment: process.env.APNS_ENVIRONMENT ?? "sandbox",
});

let state = { devices: [], chatCursors: {} };
try {
  const stored = JSON.parse(await readFile(dataFile, "utf8"));
  if (
    Array.isArray(stored.devices) &&
    stored.chatCursors &&
    typeof stored.chatCursors === "object"
  ) {
    state = stored;
  }
} catch (error) {
  if (error.code !== "ENOENT") throw error;
}
let writeQueue = Promise.resolve();
function persist() {
  const snapshot = JSON.stringify(state, null, 2);
  writeQueue = writeQueue
    .catch(() => {})
    .then(async () => {
      await mkdir(dirname(dataFile), { recursive: true, mode: 0o700 });
      const temp = `${dataFile}.${process.pid}.tmp`;
      await writeFile(temp, snapshot, { mode: 0o600 });
      await rename(temp, dataFile);
    });
  return writeQueue;
}

function authorized(request) {
  const authorization = request.headers.authorization ?? "";
  if (!authorization.startsWith("Bearer ")) return false;
  const candidate = createHash("sha256")
    .update(authorization.slice(7))
    .digest();
  return timingSafeEqual(candidate, secretHash);
}

const server = createServer(async (request, response) => {
  if (request.method === "GET" && request.url === "/health") {
    response.writeHead(200, { "content-type": "application/json" });
    response.end(JSON.stringify({ ok: true }));
    return;
  }
  if (request.method !== "POST" || request.url !== "/register") {
    response.writeHead(404).end();
    return;
  }
  if (!authorized(request)) {
    response.writeHead(401).end();
    return;
  }
  try {
    const chunks = [];
    let length = 0;
    for await (const chunk of request) {
      length += chunk.length;
      if (length > 4096) throw new Error("Payload too large");
      chunks.push(chunk);
    }
    const { deviceToken, companyId: requestedCompany } = JSON.parse(
      Buffer.concat(chunks).toString("utf8"),
    );
    if (
      requestedCompany !== companyId ||
      !/^[0-9a-f]{64}$/i.test(deviceToken ?? "")
    ) {
      response.writeHead(400).end("Invalid device token or company ID");
      return;
    }
    const existing = state.devices.find(
      (device) => device.token === deviceToken.toLowerCase(),
    );
    if (!existing) {
      const device = {
        token: deviceToken.toLowerCase(),
        registeredAt: new Date().toISOString(),
      };
      state.devices.push(device);
      void announce(device);
    }
    console.log(
      `Device ${deviceToken.slice(0, 8)}... ${existing ? "already registered" : "registered"}; ${state.devices.length} total`,
    );
    await persist();
    response.writeHead(200, { "content-type": "application/json" });
    response.end(JSON.stringify({ ok: true }));
  } catch (error) {
    console.error("Push registration error:", error);
    response.writeHead(400).end("Invalid request");
  }
});

const watcher = createWatcher({
  paperclipURL: process.env.PAPERCLIP_URL,
  companyId,
  boardToken: process.env.PAPERCLIP_BOARD_TOKEN,
  state,
  persist,
  deliver: (token, details) => apns.send(token, details),
});
let checking = false;
let failures = 0;
let nextAttempt = 0;
async function check() {
  if (checking || Date.now() < nextAttempt) return;
  checking = true;
  try {
    await watcher.poll();
    if (failures) console.log("Paperclip reachable again");
    failures = 0;
  } catch (error) {
    failures++;
    // Back off up to 2 minutes and keep the log to one line per failure.
    nextAttempt =
      Date.now() + Math.min(120000, 5000 * 2 ** Math.min(failures, 5));
    const reason = error.cause?.code ?? error.cause?.message ?? error.message;
    console.error(
      `Paperclip unreachable or failing (attempt ${failures}): ${reason}`,
    );
  } finally {
    checking = false;
  }
}
async function announce(device) {
  try {
    const result = await apns.send(device.token, {
      agentName: "Paperclip Pocket",
      message: "Push relay connected",
      companyId,
      type: "connected",
    });
    if (result?.unregister)
      console.error(
        `APNs rejected token ${device.token.slice(0, 8)}...: ${result.reason}`,
      );
    else console.log(`Connected notification sent to ${device.token.slice(0, 8)}...`);
  } catch (error) {
    console.error("Connected notification failed:", error.message);
  }
}
process.on("unhandledRejection", (error) =>
  console.error("Unhandled rejection:", error),
);
process.on("uncaughtException", (error) =>
  console.error("Uncaught exception:", error),
);
const interval = Math.max(
  5000,
  Number(process.env.PUSH_POLL_INTERVAL_MS ?? 15000),
);
server.listen(
  Number(process.env.PUSH_PORT ?? 8088),
  process.env.PUSH_BIND ?? "127.0.0.1",
  () => {
    console.log(
      `Push relay started; watching company ${companyId} every ${interval}ms`,
    );
    void check();
    setInterval(() => void check(), interval).unref();
  },
);
