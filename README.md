# Paperclip Pocket

A native SwiftUI iOS client for [Paperclip](https://github.com/paperclipai/paperclip), with an optional Node.js relay for APNs notifications while the app is in the background or closed.

| Feature            | Implementation                                                                                                                                                                              |
| ------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Tasks              | Search and filter issues by status, project, and assignee. View and edit task title, description, status, priority, assignee, and project.                                                  |
| Comments and files | Read and post Markdown comments, attach photos or files, and see existing comment attachments. Threads mark themselves read when refreshed.                                                 |
| Agent Chat         | Browse agents and persistent per-agent conversations. New chats are created on first message. The app displays run transcripts, tool activity, and live status when Paperclip exposes them. |
| Live updates       | Uses Paperclip's authenticated WebSocket event stream and periodic refreshes to keep an open thread current and recover after reconnects.                                                   |
| Browser sign-in    | Approve board access through Paperclip in an in-app browser, then choose a company. Manual board-token entry remains available under Advanced login.                                        |
| Push notifications | An optional relay polls unread chats and issue threads, then sends APNs alerts for new comments and detected issue status changes. Tapping an alert opens its thread.                       |
| Secret storage     | The Paperclip board token and push relay secret are stored in the iOS Keychain. The APNs private key stays on the relay host.                                                               |

## Requirements

- Xcode 16 or newer, iOS 17+, macOS, and a **physical iPhone** for APNs testing. The simulator can be used to browse tasks and chat, but not to verify real device push delivery.
- A working [Paperclip](https://github.com/paperclipai/paperclip) server accessible from your phone over **HTTPS**. It can be a private HTTPS endpoint over a VPN; do not expose `local_trusted` Paperclip publicly.
- In authenticated mode, sign in as a **board user** in your Paperclip instance. The app creates a board token automatically through Paperclip’s existing CLI challenge approval API. For older instances you can still paste an existing board token under Advanced login. Board tokens grant broad authority; safeguard your device.
- To turn on Agent Chat: Paperclip **Instance Settings → Experimental → Agent Chat** (internal setting `enableAgentChat`). You can still browse tasks with Agent Chat off.
- For push: an Apple Developer team, APNs Auth Key (`.p8`), APNs-enabled App ID, and a host running Node.js 20+ with a reachable HTTPS reverse proxy.

## 1. Run the iOS app

1. Open `PaperclipPocket.xcodeproj` in Xcode.
2. Under **Signing & Capabilities**, select your Apple Developer team, change the example bundle identifier (`dev.example.PaperclipPocket`) to a unique ID registered to your team, and enable **Push Notifications**. The project includes `aps-environment` development entitlement for device debug builds. Configure signing/provisioning for distribution separately.
3. Run on an iPhone. Tasks and chat can also be used in the simulator.
4. Under the app’s **Settings** tab, enter your Paperclip HTTPS base URL (e.g. `https://paperclip.example.com`) and tap **Sign in with Paperclip**. The app opens the Paperclip approval page in a secure browser view; log in with your existing Paperclip account and approve the access request. Once approved, the app verifies the credential and automatically fetches your companies. Choose a different company if necessary, then tap **Save settings**.
5. Browse **Tasks** or **Chat**. The Tasks tab loads issues touched by the signed-in user, with search and status, project, and agent filters. Open a task to edit its properties, read or post comments, and attach files. In Chat, open an agent to continue that user's persistent conversation or send the first message to create one.

You do **not** have to run the CLI or manually create a board token. The app uses `POST /api/cli-auth/challenges` to start a browser-approval challenge, checks `GET /api/cli-auth/challenges/:id?token=...` for approval, verifies `GET /api/cli-auth/me`, then saves the approved board token in Keychain. It only uses HTTPS server origins. These endpoints are designed for client approval flows; no account password is collected by the app.

If you prefer the advanced manual-token option, you can still create a board token using Paperclip’s CLI:

```sh
npx paperclipai auth login --api-base https://paperclip.example.com
npx paperclipai token board create --name paperclip-pocket --ttl-days 30
```

The token is printed only at creation time. Paste it under **Advanced login** if using this route; keep it out of code and version control. In Paperclip authenticated mode, use the token of the same board user whose conversations you want to access.

You can enable chat from the web UI or with the Paperclip CLI:

```sh
npx paperclipai instance settings:experimental:update \
  --payload-json '{"enableAgentChat":true}'
```

## 2. Set up APNs push notifications (optional, still work in progress 🚧)

The iPhone app **cannot reliably poll Paperclip while suspended**. The relay therefore runs on an always-on machine, checks the configured user's unread chats and issue threads every 15 seconds by default, and contacts Apple directly.

1. Create an APNs Auth Key in your Apple Developer account and note the Key ID and Team ID. Configure the bundle ID/App ID for Push Notifications.
2. Copy `PushRelay/.env.example` to `PushRelay/.env` and fill in the required values. **Do not commit `.env` or `.p8` keys.** `PAPERCLIP_BOARD_TOKEN` should belong to the same board user you use on the iPhone. Set `PAPERCLIP_COMPANY_ID` to that user's company. Generate an unrelated push secret, e.g. `openssl rand -hex 32`.
3. Launch the relay. It has **no third-party dependencies**:

```sh
cd PushRelay
set -a
source .env
set +a
node server.js
```

The relay requires Node.js 20 or newer. It does not load `.env` itself; the commands above export its values into the process environment.

The relay requires these settings:

| Variable                | Purpose                                              |
| ----------------------- | ---------------------------------------------------- |
| `PAPERCLIP_URL`         | HTTPS Paperclip origin                               |
| `PAPERCLIP_COMPANY_ID`  | Company watched by the relay                         |
| `PAPERCLIP_BOARD_TOKEN` | Board user's token; use the same user as the iOS app |
| `PUSH_RELAY_SECRET`     | Shared secret entered in the iOS app                 |
| `APNS_TEAM_ID`          | Apple Developer team ID                              |
| `APNS_KEY_ID`           | APNs Auth Key ID                                     |
| `APNS_BUNDLE_ID`        | Bundle ID signed into the iOS app                    |
| `APNS_PRIVATE_KEY_PATH` | Path to the APNs `.p8` file                          |

Optional settings are `APNS_ENVIRONMENT` (`sandbox` by default; use `production` for distribution builds), `PUSH_PORT` (`8088`), `PUSH_BIND` (`127.0.0.1`), `PUSH_DATA_FILE` (`./data/state.json`), and `PUSH_POLL_INTERVAL_MS` (`15000`, minimum `5000`).

You can also build and run the included Docker image from the repository root. Set `APNS_PRIVATE_KEY_PATH` in `.env` to the path inside the container, and replace the mounted host key path below:

```sh
docker build -t paperclip-pocket-relay ./PushRelay
docker run -d --name paperclip-pocket-relay --restart unless-stopped \
  --env-file PushRelay/.env \
  --env PUSH_BIND=0.0.0.0 \
  --env APNS_PRIVATE_KEY_PATH=/run/secrets/apns.p8 \
  --publish 127.0.0.1:8088:8088 \
  --mount type=volume,src=paperclip-pocket-data,dst=/app/data \
  --mount type=bind,src=/secure/path/AuthKey_XXXXXXXXXX.p8,dst=/run/secrets/apns.p8,readonly \
  paperclip-pocket-relay
```

The named Docker volume keeps relay state across container replacement. The published port is loopback-only so a host reverse proxy can provide HTTPS.

4. Put the relay behind HTTPS, for example with a Caddy reverse proxy:

```caddyfile
push.example.com {
    reverse_proxy 127.0.0.1:8088
}
```

5. In the iOS app's Settings, enter `https://push.example.com` and the same `PUSH_RELAY_SECRET`. Tap **Enable notifications**, grant the Apple permission dialog, and verify that the app reports **Notifications enabled**.
6. Send a message to an agent and have the agent respond. The relay should send an APNs alert with the agent name and a reply preview. Tapping it opens the corresponding thread.

> Use `APNS_ENVIRONMENT=sandbox` for a development-signed iPhone build and `production` for a distribution build. `APNS_BUNDLE_ID` must match the signed app's bundle identifier. The relay must be able to reach Apple's APNs host, and the phone must have network access to Paperclip when you open the notification.

### Push relay endpoints

- `GET /health` — readiness response (no authentication).
- `POST /register` — requires `Authorization: Bearer <PUSH_RELAY_SECRET>` and JSON `{"deviceToken":"<64 hex>","companyId":"<company UUID>"}`; this stores the APNs device token (not the Paperclip board token).

The relay binds to **127.0.0.1:8088** by default and must be placed behind TLS for iOS clients. `PUSH_POLL_INTERVAL_MS` defaults to 15000 and cannot be set below 5000. `PUSH_PORT`, `PUSH_BIND`, and `PUSH_DATA_FILE` can override the listener and state-file defaults. The Docker image uses Node.js 22, binds inside the container to `0.0.0.0:8088`, and expects persistent state at `/app/data/state.json` and the APNs key at `/run/secrets/apns.p8`.

The relay stores device tokens, registration timestamps, sent-comment IDs, and per-thread comment cursors in `PushRelay/data/state.json`. The data directory is created with mode `0700`; the state file is written with mode `0600`. Keep it private and persistent. Delete the relay data file to reset its state.

### Privacy and scope

This is a **single-user, single-company MVP**, not a multi-tenant push service. One configured board identity is used by the relay to read that user's chats and issues. The shared relay secret is suitable for a private personal deployment, not a public consumer app. Push previews contain comment text and pass through Apple APNs; if you need less disclosure on lock screens, change `apns.js` to send a generic alert. Relay logs show only the first eight characters of an APNs device token, though Paperclip error responses may appear in logs.

The relay sends alerts for new, non-empty comments not authored by a human user in unread Agent Chat conversations and watched issue threads. It watches active issues plus issues closed or cancelled within the last 24 hours. It also sends an alert when it detects an issue status change. Comment alerts are suppressed for threads the configured board user has read and for comments posted before a device registered. If Paperclip's unread query fails, the relay fails open and may send comment alerts for read threads. A new device registration triggers a one-time "Push relay connected" alert. The relay does not alert on other task-field changes or display live execution traces and tool calls. The app gets live thread activity from Paperclip's WebSocket and refreshes periodically while a thread is open. Push delivery is best-effort and depends on network access, polling, APNs availability, and valid device registration. The relay persists cursors and a bounded set of sent comment IDs to avoid replaying comments, but it does not guarantee exactly-once delivery.

## API endpoints used

| Method | Path                                             | Purpose                                                                |
| ------ | ------------------------------------------------ | ---------------------------------------------------------------------- |
| POST   | `/api/cli-auth/challenges`                       | Start browser-based device authorization                               |
| GET    | `/api/cli-auth/challenges/:id?token=...`         | Check authorization status                                             |
| GET    | `/api/cli-auth/me`                               | Verify approved board credential                                       |
| POST   | `/api/cli-auth/revoke-current`                   | Revoke credential on disconnect (best effort)                          |
| GET    | `/api/companies`                                 | Select company                                                         |
| GET    | `/api/companies/:id/issues`                      | Search/filter tasks; relay also lists issues and unread threads        |
| GET    | `/api/companies/:id/projects`                    | Project filters and task assignment                                    |
| GET    | `/api/issues/:id`                                | Task details and notification thread routing                           |
| PATCH  | `/api/issues/:id`                                | Update task title, description, status, priority, assignee, or project |
| GET    | `/api/issues/:id/comments`                       | Read task comments and chat transcript                                 |
| POST   | `/api/issues/:id/comments`                       | Send comment with idempotent `clientRequestId`                         |
| POST   | `/api/issues/:id/read`                           | Mark a thread as read                                                  |
| GET    | `/api/issues/:id/attachments`                    | List attachments on a thread                                           |
| POST   | `/api/companies/:id/issues/:issueId/attachments` | Upload attachment linked to a comment                                  |
| GET    | `/api/companies/:id/agents`                      | Agent roster and assignee choices                                      |
| GET    | `/api/companies/:id/chats`                       | Existing per-user conversations; requires experimental Agent Chat      |
| GET    | `/api/companies/:id/chats/:agentId`              | Read existing chat or null                                             |
| POST   | `/api/companies/:id/chats/:agentId`              | Create missing chat                                                    |
| WSS    | `/api/companies/:id/events/ws`                   | Authenticated live company events                                      |
| GET    | `/api/issues/:id/runs`                           | List agent runs for a thread                                           |
| GET    | `/api/heartbeat-runs/:id/log?offset=...`         | Read run log data for the transcript                                   |

The relay uses `GET /api/companies/:id/chats`, `GET /api/companies/:id/issues`, `GET /api/companies/:id/agents`, and `GET /api/issues/:id/comments` to find and deliver push alerts. It requests unread issues with `unreadForUserId=me` and uses issue `updatedAt` values to keep recently closed threads in its watch list.

References: [Paperclip API overview](https://github.com/paperclipai/paperclip-docs/blob/main/docs/reference/api/overview.md), [Issues and Agent Chat API](https://github.com/paperclipai/paperclip-docs/blob/main/docs/reference/api/issues.md), [persistent agent chat design](https://github.com/paperclipai/paperclip/blob/master/doc/plans/2026-09-10-agent-chat.md), and [CLI authentication](https://github.com/paperclipai/paperclip-docs/blob/main/docs/reference/cli/authentication.md).

## Secret scanning

Install Gitleaks and enable the repository's pre-commit hook once per clone:

```sh
brew install gitleaks
git config --local core.hooksPath .githooks
```

The hook scans staged changes and blocks a commit if it finds a secret. To run the same scan manually:

```sh
gitleaks protect --staged --redact
```

## Tests and verification

Run the relay's built-in tests with:

```sh
cd PushRelay
npm test
```

The tests mock Paperclip responses and APNs delivery. They cover new-reply filtering, read-thread suppression, newly created conversations, and duplicate suppression. To build the iOS app, open `PaperclipPocket.xcodeproj` in Xcode and select your signing team. No live Paperclip or APNs end-to-end test is included; verify API compatibility with your Paperclip version and test push delivery on a signed physical iPhone.

### Login safety and caveats

- The `boardApiToken` returned during challenge creation is **pending** and may only be stored/used after challenge status becomes `approved`. The app additionally calls `/api/cli-auth/me` to verify it before saving.
- The in-app Safari approval view requires that the Paperclip server be reachable from the iPhone and served via HTTPS. A reverse proxy must correctly expose the Paperclip routes and WebSocket upgrade for live updates.
- Board tokens are powerful. The browser flow improves onboarding, not the permission scope. For least privilege, Paperclip would need a narrower app-specific OAuth scope or API token capability.
- Disconnect attempts server-side revocation and clears the local Paperclip token. It does **not** deregister the iPhone from the push relay; remove its registration separately if you no longer want pushes.
- The separate APNs relay still needs its own board-user token. The phone’s approved credential is not automatically transmitted to the relay.

## Where to extend it

- Add attachment previews and downloads.
- Reduce periodic refreshes when the WebSocket is connected.
- Replace the shared-secret single-user relay with per-user registration and authenticated subscriptions for multi-user deployments.
