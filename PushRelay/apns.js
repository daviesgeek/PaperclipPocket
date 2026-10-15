import { createPrivateKey, sign } from "node:crypto";
import { readFileSync } from "node:fs";
import http2 from "node:http2";

/** Apple token-authenticated APNs provider, using only Node built-ins. */
export class APNsClient {
  constructor({ teamId, keyId, bundleId, keyPath, environment = "sandbox" }) {
    this.teamId = teamId;
    this.keyId = keyId;
    this.bundleId = bundleId;
    this.privateKey = createPrivateKey(readFileSync(keyPath));
    this.endpoint =
      environment === "production"
        ? "https://api.push.apple.com"
        : "https://api.sandbox.push.apple.com";
    this.jwt = null;
    this.jwtIssuedAt = 0;
  }

  authorizationToken() {
    const issuedAt = Math.floor(Date.now() / 1000);
    if (this.jwt && issuedAt - this.jwtIssuedAt < 45 * 60) return this.jwt;
    const encoded = (value) =>
      Buffer.from(JSON.stringify(value)).toString("base64url");
    const unsigned = `${encoded({ alg: "ES256", kid: this.keyId })}.${encoded({ iss: this.teamId, iat: issuedAt })}`;
    const signature = sign("sha256", Buffer.from(unsigned), {
      key: this.privateKey,
      dsaEncoding: "ieee-p1363",
    }).toString("base64url");
    this.jwt = `${unsigned}.${signature}`;
    this.jwtIssuedAt = issuedAt;
    return this.jwt;
  }

  async send(
    deviceToken,
    { agentName, message, chatIssueId, companyId, type = "agent_reply" },
  ) {
    const content = {
      aps: {
        alert: {
          title: agentName,
          body: message.slice(0, 160) || "New agent reply",
        },
        sound: "default",
        ...(chatIssueId ? { "thread-id": chatIssueId } : {}),
      },
      type,
      chatIssueId,
      companyId,
    };
    const connection = http2.connect(this.endpoint);
    connection.setTimeout(15000, () =>
      connection.destroy(new Error("APNs connection timed out")),
    );
    return new Promise((resolve, reject) => {
      let settled = false;
      const finish = (error, result) => {
        if (settled) return;
        settled = true;
        connection.close();
        error ? reject(error) : resolve(result);
      };
      connection.on("error", (error) => finish(error));
      const request = connection.request({
        ":method": "POST",
        ":path": `/3/device/${deviceToken}`,
        authorization: `bearer ${this.authorizationToken()}`,
        "apns-topic": this.bundleId,
        "apns-push-type": "alert",
        "apns-priority": "10",
        "content-type": "application/json",
      });
      let status = 0;
      let body = "";
      request.setEncoding("utf8");
      request.on("response", (headers) => {
        status = Number(headers[":status"]);
      });
      request.on("data", (chunk) => {
        body += chunk;
      });
      request.on("error", (error) => finish(error));
      request.on("end", () => {
        if (status === 200) finish(null, { success: true });
        else {
          let reason;
          try {
            reason = JSON.parse(body).reason;
          } catch {
            reason = body || "Unknown error";
          }
          if (
            status === 410 ||
            reason === "BadDeviceToken" ||
            reason === "Unregistered"
          ) {
            finish(null, { success: false, unregister: true, reason });
          } else finish(new Error(`APNs HTTP ${status}: ${reason}`));
        }
      });
      request.end(JSON.stringify(content));
    });
  }
}
