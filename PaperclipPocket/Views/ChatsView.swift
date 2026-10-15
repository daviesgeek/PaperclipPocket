import Combine
import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct ChatsView: View {
    @EnvironmentObject private var store: AppStore
    @State private var roster: [Agent] = []
    @State private var conversations: [Issue] = []
    @State private var path: [ChatRoute] = []
    @State private var isDisabled = false
    @State private var error: String?
    @State private var loading = false

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if !store.configuration.isReady {
                    ContentUnavailableView("Connect Paperclip", systemImage: "link",
                                           description: Text("Configure your server in Settings."))
                } else if isDisabled {
                    ContentUnavailableView("Agent Chat is off", systemImage: "bubble.left.slash",
                        description: Text("Enable Agent Chat in Paperclip's Instance Settings → Experimental."))
                } else if loading && roster.isEmpty {
                    ProgressView("Loading agents…")
                } else if let error, roster.isEmpty {
                    ContentUnavailableView("Could not load chats", systemImage: "wifi.exclamationmark",
                                           description: Text(error))
                } else if roster.isEmpty {
                    ContentUnavailableView("No agents", systemImage: "person.3",
                                           description: Text("Create an agent in Paperclip first."))
                } else {
                    List(roster) { agent in
                        let existing = conversations.first { $0.conversationAgentId == agent.id }
                        NavigationLink(value: ChatRoute(agent: agent, issueID: existing?.id)) {
                            HStack(spacing: 12) {
                                AgentAvatar(agent: agent, size: 42)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(agent.name).font(.body.weight(.medium))
                                    Text(agent.title ?? agent.role ?? "Agent")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if existing != nil {
                                    Image(systemName: "bubble.left.fill").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    .refreshable { await load() }
                }
            }
            .navigationTitle("Chat")
            .navigationDestination(for: ChatRoute.self) { route in
                ChatDetailView(agent: route.agent, initialIssueID: route.issueID)
            }
            .toolbar {
                Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(loading || !store.configuration.isReady)
            }
            .task(id: store.configuration) { await load() }
            .onChange(of: store.requestedChatIssueID, initial: true) { _, issueID in
                guard let issueID else { return }
                Task { await openIssueFromNotification(issueID) }
            }
        }
    }

    @MainActor
    private func load() async {
        guard store.configuration.isReady else { roster = []; conversations = []; return }
        loading = true
        defer { loading = false }
        do {
            async let agentResponse = store.api.agents()
            async let chatResponse = store.api.chats()
            let (agents, chats) = try await (agentResponse, chatResponse)
            roster = agents.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            conversations = chats
            isDisabled = false
            error = nil
        } catch let failure as PaperclipAPI.APIError {
            if case let .http(code, message) = failure,
               code == 404 && message.localizedCaseInsensitiveContains("disabled") {
                isDisabled = true
                error = nil
            } else {
                error = failure.localizedDescription
            }
        } catch { self.error = error.localizedDescription }
    }

    @MainActor
    private func openIssueFromNotification(_ issueID: String) async {
        guard store.configuration.isReady else { return }
        do {
            if roster.isEmpty { await load() }
            let issue = try await store.api.issue(issueID)
            guard let agentID = issue.conversationAgentId ?? issue.assigneeAgentId else { return }
            let agent = roster.first(where: { $0.id == agentID })
                ?? Agent(id: agentID, name: "Agent", role: nil, title: nil, status: nil)
            path = [ChatRoute(agent: agent, issueID: issueID)]
            store.requestedChatIssueID = nil
        } catch { self.error = error.localizedDescription }
    }
}

struct ChatDetailView: View {
    @EnvironmentObject private var store: AppStore
    let agent: Agent
    let initialIssueID: String?

    var body: some View {
        ChatThreadView(agent: agent,
                       session: store.session(key: "chat:\(agent.id)", issueID: initialIssueID,
                                              agentID: agent.id, isChat: true))
    }
}

private struct ChatThreadView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.scenePhase) private var scenePhase
    let agent: Agent
    @ObservedObject var session: ThreadSession
    @State private var composerFocused = false

    var body: some View {
        VStack(spacing: 0) {
            if !session.loaded {
                Spacer()
                ProgressView("Loading conversation…")
                Spacer()
            } else if session.comments.isEmpty && session.activityText == nil && !session.transcript.hasRun {
                Spacer()
                ContentUnavailableView("Chat with \(agent.name)", systemImage: "bubble.left.and.text.bubble.right",
                                       description: Text("Send a message to begin your conversation."))
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            ForEach(session.comments) { comment in
                                IssueCommentBubble(comment: comment, authorName: comment.isAgentReply ? agent.name : nil,
                                                   attachments: session.attachments.filter { $0.issueCommentId == comment.id })
                                    .id(comment.id)
                            }
                            if session.transcript.hasRun {
                                RunActivityView(run: session.transcript).id("run")
                            }
                            if let activity = session.activityText {
                                AgentActivityRow(text: activity).id("activity")
                            }
                        }
                        .padding()
                    }
                    .defaultScrollAnchor(.bottom)
                    .onChange(of: session.comments.last?.id) { _, newID in
                        if let newID { withAnimation { proxy.scrollTo(newID, anchor: .bottom) } }
                    }
                    .onChange(of: session.activityText) { _, newValue in
                        if newValue != nil { withAnimation { proxy.scrollTo("activity", anchor: .bottom) } }
                    }
                    .onChange(of: session.transcript.entries.count) { _, _ in
                        if session.transcript.isRunning { proxy.scrollTo("run", anchor: .bottom) }
                    }
                }
            }
            if let error = session.error {
                Text(error).font(.caption).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.vertical, 5)
            }
        }
        .background(Color(.systemGroupedBackground))
        .safeAreaInset(edge: .bottom, spacing: 0) {
            IssueCommentComposer(draft: $session.draft, pendingFiles: $session.pendingFiles, isFocused: $composerFocused,
                                 sending: session.sending, placeholder: "Message \(agent.name)…",
                                 onSend: { composerFocused = false; Task { await session.send(api: store.api) } },
                                 onError: { session.error = $0 })
        }
        .navigationTitle(agent.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 8) {
                    AgentAvatar(agent: agent, size: 28)
                    Text(agent.name).font(.headline)
                }
            }
        }
        .task { await session.listen(api: store.api) }
        .task { await session.poll(api: store.api) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await session.refresh(api: store.api) } }
        }
    }
}

/// State for one comment thread (chat or task): messages, run transcript, composer, and live resync.
/// Cached by AppStore so reopening a thread shows its last state immediately and resumes the run log.
@MainActor
final class ThreadSession: ObservableObject {
    @Published private(set) var issueID: String?
    @Published private(set) var comments: [IssueComment] = []
    @Published private(set) var attachments: [IssueAttachment] = []
    @Published private(set) var loaded = false
    @Published private(set) var sending = false
    @Published private(set) var thinking = false
    @Published private(set) var liveLine: String?
    @Published var error: String?
    @Published var draft = ""
    @Published var pendingFiles: [PendingAttachment] = []

    let transcript = RunTranscript()
    var agentID: String?
    var onRefresh: (() async -> Void)?

    private let isChat: Bool
    private var forwarding: AnyCancellable?
    private var optimistic: [IssueComment] = []
    private var refreshing = false
    private var refreshAgain = false
    private var readMarker: String?
    private var thinkingSince = Date.distantPast
    private var liveSince = Date.distantPast
    private var requestID: UUID?
    private var requestBody = ""
    private var postedCommentID: String?

    init(issueID: String?, agentID: String?, isChat: Bool) {
        self.issueID = issueID
        self.agentID = agentID
        self.isChat = isChat
        forwarding = transcript.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    func adopt(issueID: String?, agentID: String?) {
        if self.issueID == nil, let issueID { self.issueID = issueID }
        if let agentID { self.agentID = agentID }
    }

    var isWorking: Bool { transcript.isRunning || thinking || liveLine != nil }

    /// Status line shown only when there is no live run transcript to display.
    var activityText: String? {
        guard !transcript.isRunning else { return nil }
        return liveLine ?? (thinking ? "Thinking…" : nil)
    }

    private func matches(_ event: LiveEvent) -> Bool {
        if let eventIssue = event.issueId { return eventIssue == issueID }
        return event.agentId != nil && event.agentId == agentID
    }

    func listen(api: PaperclipAPI) async {
        for await event in api.liveEvents() {
            if event.type == LiveEvent.reconnectType { await refresh(api: api); continue }
            guard matches(event) else { continue }
            liveLine = liveActivity(current: liveLine, event: event)
            if liveLine != nil { liveSince = .now }
            if ["comment", "finished", "failed", "cancelled", "issue.updated"].contains(where: event.type.contains) {
                await refresh(api: api)
            }
        }
    }

    func poll(api: PaperclipAPI) async {
        while !Task.isCancelled {
            await refresh(api: api)
            try? await Task.sleep(for: .seconds(isWorking ? 2 : 6))
        }
    }

    /// Single-flight: overlapping requests coalesce into one extra pass.
    func refresh(api: PaperclipAPI) async {
        if refreshing { refreshAgain = true; return }
        refreshing = true
        defer { refreshing = false }
        repeat {
            refreshAgain = false
            await load(api: api)
        } while refreshAgain && !Task.isCancelled
    }

    private func load(api: PaperclipAPI) async {
        do {
            if issueID == nil, isChat, let agentID { issueID = try await api.existingChat(agentID: agentID)?.id }
            guard let id = issueID else { loaded = true; return }
            async let list = api.comments(issueID: id)
            async let files = api.attachments(issueID: id)
            let fresh = try await list
            attachments = (try? await files) ?? attachments
            let known = Set(fresh.map(\.id))
            optimistic.removeAll { known.contains($0.id) }
            comments = fresh + optimistic
            loaded = true
            error = nil
            if let last = comments.last?.id, last != readMarker {
                readMarker = last
                try? await api.markRead(issueID: id)
            }
            await transcript.refresh(api: api, issueID: id)
            await onRefresh?()
            settle()
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { return }
            loaded = true
            self.error = error.localizedDescription
        }
    }

    private func settle() {
        if transcript.isRunning { thinking = false }
        else if thinking, comments.last?.isAgentReply == true || Date.now.timeIntervalSince(thinkingSince) > 45 {
            thinking = false
        }
        if !transcript.isRunning, liveLine != nil, Date.now.timeIntervalSince(liveSince) > 10 { liveLine = nil }
    }

    func send(api: PaperclipAPI) async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !pendingFiles.isEmpty, !sending else { return }
        sending = true
        defer { sending = false }
        do {
            if issueID == nil, isChat, let agentID { issueID = try await api.openChat(agentID: agentID).id }
            guard let id = issueID else { return }
            if !text.isEmpty { postedCommentID = nil }
            if postedCommentID == nil {
                let body = text.isEmpty ? "Attached \(pendingFiles.count) file(s)." : text
                // Retrying the same body reuses the request ID so the server can dedupe.
                if requestBody != body || requestID == nil { requestID = UUID(); requestBody = body }
                let comment = try await api.sendMessage(body, issueID: id, clientRequestID: requestID!)
                requestID = nil
                postedCommentID = comment.id
                if !comments.contains(where: { $0.id == comment.id }) {
                    optimistic.append(comment)
                    comments.append(comment)
                }
                draft = ""
                thinking = true
                thinkingSince = .now
            }
            if let commentID = postedCommentID {
                while let file = pendingFiles.first {
                    try await api.upload(file, issueID: id, commentID: commentID)
                    pendingFiles.removeFirst()
                }
            }
            postedCommentID = nil
            error = nil
            await refresh(api: api)
        } catch { self.error = error.localizedDescription }
    }
}

struct IssueCommentBubble: View {
    let comment: IssueComment
    let authorName: String?
    let attachments: [IssueAttachment]

    private var fromPerson: Bool { comment.authorUserId != nil && !comment.isAgentReply }
    private var displayName: String {
        comment.isAgentReply ? (authorName ?? "Agent") : (fromPerson ? "You" : "System")
    }

    var body: some View {
        HStack {
            if fromPerson { Spacer(minLength: 45) }
            VStack(alignment: .leading, spacing: 5) {
                Text(displayName).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                MarkdownText(comment.body)
                ForEach(attachments) { file in
                    Label(file.originalFilename ?? "Attachment",
                          systemImage: (file.contentType ?? "").hasPrefix("image/") ? "photo" : "paperclip")
                        .font(.caption)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.quaternary, in: Capsule())
                }
            }
            .padding(12)
            .background(fromPerson ? Color.accentColor.opacity(0.16) : Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 14))
            if !fromPerson { Spacer(minLength: 45) }
        }
    }
}

struct IssueCommentComposer: View {
    @Binding var draft: String
    @Binding var pendingFiles: [PendingAttachment]
    @Binding var isFocused: Bool
    let sending: Bool
    let placeholder: String
    let onSend: () -> Void
    let onError: (String) -> Void

    @State private var photoSelection: [PhotosPickerItem] = []
    @State private var showPhotoPicker = false
    @State private var showFileImporter = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !pendingFiles.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(pendingFiles) { file in
                            HStack(spacing: 4) {
                                Image(systemName: file.mimeType.hasPrefix("image/") ? "photo" : "doc")
                                Text(file.name).lineLimit(1).frame(maxWidth: 140)
                                Button { pendingFiles.removeAll { $0.id == file.id } } label: {
                                    Image(systemName: "xmark.circle.fill")
                                }
                                .accessibilityLabel("Remove \(file.name)")
                            }
                            .font(.caption)
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(.quaternary, in: Capsule())
                        }
                    }
                }
            }
            HStack(alignment: .bottom, spacing: 9) {
                Menu {
                    Button { showPhotoPicker = true } label: { Label("Photo Library", systemImage: "photo") }
                    Button { showFileImporter = true } label: { Label("Files", systemImage: "doc") }
                } label: {
                    Image(systemName: "plus.circle.fill").font(.system(size: 30)).foregroundStyle(.secondary)
                }
                .accessibilityLabel("Attach")
                PasteableTextView(text: $draft, isFocused: $isFocused, placeholder: placeholder, maxLines: 5) { pasted in
                    pendingFiles.append(contentsOf: pasted)
                }
                .padding(11)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
                Button(action: onSend) {
                    if sending { ProgressView().frame(width: 30, height: 30) }
                    else { Image(systemName: "arrow.up.circle.fill").font(.system(size: 30)) }
                }
                .disabled(sending || (draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && pendingFiles.isEmpty))
                .accessibilityLabel("Send message")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.regularMaterial)
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoSelection, maxSelectionCount: 5, matching: .images)
        .onChange(of: photoSelection) { _, items in
            guard !items.isEmpty else { return }
            Task { await addPhotos(items) }
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            addFiles(result)
        }
    }

    @MainActor
    private func addPhotos(_ items: [PhotosPickerItem]) async {
        defer { photoSelection = [] }
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            let type = item.supportedContentTypes.first
            let ext = type?.preferredFilenameExtension ?? "jpg"
            pendingFiles.append(PendingAttachment(name: "photo-\(pendingFiles.count + 1).\(ext)",
                                                  mimeType: type?.preferredMIMEType ?? "image/jpeg", data: data))
        }
    }

    private func addFiles(_ result: Result<[URL], Error>) {
        switch result {
        case let .success(urls):
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                guard let data = try? Data(contentsOf: url) else { continue }
                let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                pendingFiles.append(PendingAttachment(name: url.lastPathComponent, mimeType: mime, data: data))
            }
        case let .failure(failure):
            onError(failure.localizedDescription)
        }
    }
}

/// Maps a live run event to a short status line, or nil when the run is over.
func liveActivity(current: String?, event: LiveEvent) -> String? {
    let type = event.type
    if type.contains("finished") || type.contains("failed") || type.contains("cancelled") { return nil }
    if type.contains("queued") || type.contains("started") { return "Working…" }
    if type.contains("run.log") || type.contains("run.status") {
        let line = event.text?
            .split(whereSeparator: \.isNewline)
            .last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
            .map { String($0.trimmingCharacters(in: .whitespaces).prefix(140)) }
        return line ?? current ?? "Working…"
    }
    return current
}

struct AgentActivityRow: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Rebuilds an agent run's transcript (narration, tool calls, usage) from its run log.
@MainActor
final class RunTranscript: ObservableObject {
    struct ToolCall {
        var title = "Used a tool"
        var command = ""
        var output = ""
        var status: String?
        var exitCode: Int?
    }
    enum Kind { case text(String), tool(ToolCall) }
    struct Entry: Identifiable { let id: Int; var kind: Kind }

    @Published private(set) var entries: [Entry] = []
    @Published private(set) var status: String?
    @Published private(set) var startedAt: Date?
    @Published private(set) var finishedAt: Date?
    @Published private(set) var tokens = 0

    private var runID: String?
    private var offset = 0
    private var rawBuffer = ""
    private var stdoutBuffer = ""
    private var toolIndex: [String: Int] = [:]
    private var logTokens = 0

    var hasRun: Bool { runID != nil }
    var isRunning: Bool { ["queued", "running"].contains(status ?? "") }
    var toolCount: Int { entries.filter { if case .tool = $0.kind { return true } else { return false } }.count }

    func refresh(api: PaperclipAPI, issueID: String) async {
        guard let runs = try? await api.rawJSON("issues/\(issueID)/runs") as? [[String: Any]],
              let latest = runs.max(by: { sortKey($0) < sortKey($1) }),
              let id = (latest["runId"] ?? latest["id"]) as? String else { return }
        if id != runID { reset(); runID = id }
        status = latest["status"] as? String
        startedAt = Self.date(latest["startedAt"] ?? latest["createdAt"])
        finishedAt = Self.date(latest["finishedAt"])
        let usage = latest["usageJson"] as? [String: Any] ?? [:]
        let runTokens = ["inputTokens", "outputTokens", "cachedInputTokens"]
            .reduce(0) { $0 + ((usage[$1] as? NSNumber)?.intValue ?? 0) }

        for _ in 0..<20 {
            guard let log = try? await api.rawJSON("heartbeat-runs/\(id)/log",
                                                   query: [URLQueryItem(name: "offset", value: String(offset))]) as? [String: Any],
                  let content = log["content"] as? String, !content.isEmpty else { break }
            offset = (log["nextOffset"] as? NSNumber)?.intValue ?? offset + content.utf8.count
            ingest(content)
            if log["nextOffset"] == nil { break }
        }
        tokens = max(runTokens, logTokens)
    }

    private func reset() {
        entries = []; offset = 0; rawBuffer = ""; stdoutBuffer = ""; toolIndex = [:]; logTokens = 0; tokens = 0
    }

    private func sortKey(_ run: [String: Any]) -> String {
        (run["createdAt"] as? String) ?? (run["startedAt"] as? String) ?? ""
    }

    private static func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    // Log content is NDJSON of {stream, chunk}; stdout chunks are themselves adapter JSON lines.
    private func ingest(_ content: String) {
        rawBuffer += content
        var lines = rawBuffer.components(separatedBy: "\n")
        rawBuffer = lines.removeLast()
        for line in lines where !line.isEmpty {
            guard let data = line.data(using: .utf8),
                  let outer = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if let stream = outer["stream"] as? String, stream != "stdout" { continue }
            stdoutBuffer += (outer["chunk"] as? String) ?? ""
        }
        var events = stdoutBuffer.components(separatedBy: "\n")
        stdoutBuffer = events.removeLast()
        for event in events {
            guard let data = event.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            process(object)
        }
    }

    private func addText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { entries.append(Entry(id: entries.count, kind: .text(trimmed))) }
    }

    private func upsertTool(_ key: String?, _ update: (inout ToolCall) -> Void) {
        if let key, let index = toolIndex[key], case var .tool(call) = entries[index].kind {
            update(&call)
            entries[index].kind = .tool(call)
            return
        }
        var call = ToolCall()
        update(&call)
        if let key { toolIndex[key] = entries.count }
        entries.append(Entry(id: entries.count, kind: .tool(call)))
    }

    private func addUsage(_ usage: [String: Any]?) {
        guard let usage else { return }
        logTokens += ["input_tokens", "output_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"]
            .reduce(0) { $0 + ((usage[$1] as? NSNumber)?.intValue ?? 0) }
    }

    private func process(_ object: [String: Any]) {
        switch object["type"] as? String {
        case "item.started", "item.updated", "item.completed":
            guard let item = object["item"] as? [String: Any], let type = item["type"] as? String else { return }
            let id = item["id"] as? String
            switch type {
            case "agent_message":
                if object["type"] as? String == "item.completed" { addText(item["text"] as? String ?? "") }
            case "reasoning": break
            case "command_execution":
                upsertTool(id) {
                    $0.title = "Ran a command"
                    $0.command = item["command"] as? String ?? ""
                    $0.output = item["aggregated_output"] as? String ?? ""
                    $0.status = item["status"] as? String
                    $0.exitCode = (item["exit_code"] as? NSNumber)?.intValue
                }
            default:
                upsertTool(id) {
                    $0.title = type.replacingOccurrences(of: "_", with: " ").capitalized
                    $0.command = (item["tool"] as? String) ?? (item["query"] as? String) ?? ""
                    $0.status = item["status"] as? String
                }
            }
        case "turn.completed":
            addUsage(object["usage"] as? [String: Any])
        case "assistant":
            guard let blocks = (object["message"] as? [String: Any])?["content"] as? [[String: Any]] else { return }
            for block in blocks {
                if block["type"] as? String == "text" { addText(block["text"] as? String ?? "") }
                if block["type"] as? String == "tool_use" {
                    let name = block["name"] as? String ?? "tool"
                    let input = block["input"] as? [String: Any] ?? [:]
                    upsertTool(block["id"] as? String) {
                        $0.title = name == "Bash" ? "Ran a command" : "Used \(name)"
                        $0.command = (input["command"] as? String)
                            ?? (try? JSONSerialization.data(withJSONObject: input)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
                    }
                }
            }
        case "user":
            guard let blocks = (object["message"] as? [String: Any])?["content"] as? [[String: Any]] else { return }
            for block in blocks where block["type"] as? String == "tool_result" {
                var text = block["content"] as? String ?? ""
                if let parts = block["content"] as? [[String: Any]] { text = parts.compactMap { $0["text"] as? String }.joined(separator: "\n") }
                let failed = block["is_error"] as? Bool == true
                upsertTool(block["tool_use_id"] as? String) { $0.output = text; $0.status = failed ? "failed" : "completed" }
            }
        case "result":
            addUsage(object["usage"] as? [String: Any])
        default: break
        }
    }
}

/// Collapsible run activity: expanded while the agent works, collapsed once it finishes.
struct RunActivityView: View {
    @ObservedObject var run: RunTranscript
    @State private var expanded = false

    private func duration(until now: Date) -> String {
        guard let start = run.startedAt else { return "" }
        let seconds = max(0, Int((run.finishedAt ?? now).timeIntervalSince(start)))
        return seconds >= 60 ? "\(seconds / 60)m \(seconds % 60)s" : "\(seconds)s"
    }

    private var tokenText: String {
        run.tokens >= 1000 ? String(format: "%.1fk tokens", Double(run.tokens) / 1000) : "\(run.tokens) tokens"
    }

    private func headerText(at now: Date) -> String {
        var parts = ["Activity", duration(until: now)]
        let tools = run.toolCount
        if tools > 0 { parts.append("\(tools) tool\(tools == 1 ? "" : "s")") }
        if run.tokens > 0 { parts.append(tokenText) }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(run.entries) { entry in
                    switch entry.kind {
                    case let .text(text): MarkdownText(text)
                    case let .tool(call): ToolCallRow(call: call)
                    }
                }
            }
            .padding(.top, 6)
        } label: {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack(spacing: 6) {
                    if run.isRunning { ProgressView().controlSize(.mini) }
                    Text(headerText(at: context.date))
                }
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            }
        }
        .onAppear { expanded = run.isRunning }
        .onChange(of: run.isRunning) { _, running in expanded = running }
    }
}

struct ToolCallRow: View {
    let call: RunTranscript.ToolCall

    private var detail: String {
        var lines: [String] = []
        if !call.command.isEmpty { lines.append("command: \(call.command)") }
        if let status = call.status { lines.append("status: \(status)") }
        if let code = call.exitCode { lines.append("exit_code: \(code)") }
        if !call.output.isEmpty {
            lines.append("")
            let output = call.output.split(separator: "\n", omittingEmptySubsequences: false)
            lines.append(output.prefix(40).joined(separator: "\n") + (output.count > 40 ? "\n…" : ""))
        }
        return lines.joined(separator: "\n")
    }

    var body: some View {
        DisclosureGroup {
            ScrollView(.horizontal, showsIndicators: false) {
                Text(detail).font(.caption.monospaced()).textSelection(.enabled).padding(8)
            }
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        } label: {
            Label(call.command.isEmpty ? call.title : "\(call.title)  \(call.command)", systemImage: "terminal")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

/// Multiline input that turns pasted images and files into attachments; plain text pastes normally.
struct PasteableTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    let placeholder: String
    let maxLines: Int
    let onPasteAttachments: ([PendingAttachment]) -> Void

    private static let attachmentTypes: [UTType] = [.image, .pdf, .movie, .archive]

    final class PasteTextView: UITextView {
        var onPaste: (([PendingAttachment]) -> Void)?

        private func attachmentType(of provider: NSItemProvider) -> UTType? {
            provider.registeredTypeIdentifiers.compactMap { UTType($0) }
                .first { type in PasteableTextView.attachmentTypes.contains { type.conforms(to: $0) } }
        }

        private var hasAttachments: Bool {
            UIPasteboard.general.itemProviders.contains { attachmentType(of: $0) != nil }
        }

        override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
            if action == #selector(paste(_:)), hasAttachments { return true }
            return super.canPerformAction(action, withSender: sender)
        }

        override func paste(_ sender: Any?) {
            let providers = UIPasteboard.general.itemProviders.filter { attachmentType(of: $0) != nil }
            guard !providers.isEmpty else { return super.paste(sender) }
            for provider in providers {
                guard let type = attachmentType(of: provider) else { continue }
                provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { [weak self] data, _ in
                    guard let data else { return }
                    let ext = type.preferredFilenameExtension ?? "bin"
                    let base = provider.suggestedName ?? "pasted-\(UUID().uuidString.prefix(6))"
                    let name = base.hasSuffix(".\(ext)") ? base : "\(base).\(ext)"
                    let file = PendingAttachment(name: name, mimeType: type.preferredMIMEType ?? "application/octet-stream", data: data)
                    DispatchQueue.main.async { self?.onPaste?([file]) }
                }
            }
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: PasteableTextView
        weak var placeholderLabel: UILabel?
        init(_ parent: PasteableTextView) { self.parent = parent }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            placeholderLabel?.isHidden = !textView.text.isEmpty
        }
        func textViewDidBeginEditing(_ textView: UITextView) { parent.isFocused = true }
        func textViewDidEndEditing(_ textView: UITextView) { parent.isFocused = false }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> PasteTextView {
        let view = PasteTextView()
        view.delegate = context.coordinator
        view.font = .preferredFont(forTextStyle: .body)
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let label = UILabel()
        label.text = placeholder
        label.font = view.font
        label.textColor = .placeholderText
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: view.topAnchor),
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor)
        ])
        context.coordinator.placeholderLabel = label
        return view
    }

    func updateUIView(_ view: PasteTextView, context: Context) {
        context.coordinator.parent = self
        view.onPaste = onPasteAttachments
        if view.text != text { view.text = text }
        context.coordinator.placeholderLabel?.isHidden = !text.isEmpty
        if !isFocused, view.isFirstResponder { view.resignFirstResponder() }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: PasteTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 200
        let line = uiView.font?.lineHeight ?? 20
        let fitted = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        return CGSize(width: width, height: min(max(fitted, line), line * CGFloat(maxLines)))
    }
}

struct AgentAvatar: View {
    @EnvironmentObject private var store: AppStore
    let agent: Agent
    var size: CGFloat = 40

    var body: some View {
        AsyncImage(url: store.api.avatarURL(for: agent, size: size)) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else {
                Image(systemName: "cpu").foregroundStyle(.tint)
            }
        }
        .frame(width: size, height: size)
        .background(.quaternary)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.26))
    }
}

/// Renders block-level Markdown (headings, lists, quotes, code fences) with inline styling.
struct MarkdownText: View {
    private enum Block: Identifiable {
        case text(Int, String), heading(Int, String), bullet(Int, String), quote(Int, String), code(Int, String)
        var id: Int {
            switch self {
            case let .text(i, _), let .heading(i, _), let .bullet(i, _), let .quote(i, _), let .code(i, _): return i
            }
        }
    }

    private let blocks: [Block]

    init(_ source: String) {
        var result: [Block] = []
        var code: [String]?
        var paragraph: [String] = []
        func flush() {
            if !paragraph.isEmpty { result.append(.text(result.count, paragraph.joined(separator: "\n"))); paragraph = [] }
        }
        for line in source.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if let lines = code { result.append(.code(result.count, lines.joined(separator: "\n"))); code = nil }
                else { flush(); code = [] }
            } else if code != nil {
                code?.append(line)
            } else if trimmed.isEmpty {
                flush()
            } else if trimmed.hasPrefix("#") {
                flush()
                result.append(.heading(result.count, trimmed.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)))
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                flush()
                result.append(.bullet(result.count, String(trimmed.dropFirst(2))))
            } else if trimmed.hasPrefix(">") {
                flush()
                result.append(.quote(result.count, trimmed.dropFirst().trimmingCharacters(in: .whitespaces)))
            } else {
                paragraph.append(line)
            }
        }
        if let lines = code { result.append(.code(result.count, lines.joined(separator: "\n"))) }
        flush()
        blocks = result
    }

    private func inline(_ text: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return Text((try? AttributedString(markdown: text, options: options)) ?? AttributedString(text))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(blocks) { block in
                switch block {
                case let .text(_, text): inline(text)
                case let .heading(_, text): inline(text).font(.headline)
                case let .bullet(_, text):
                    HStack(alignment: .firstTextBaseline, spacing: 6) { Text("•"); inline(text) }
                case let .quote(_, text):
                    inline(text).foregroundStyle(.secondary)
                        .padding(.leading, 8)
                        .overlay(alignment: .leading) { Rectangle().fill(.secondary).frame(width: 2) }
                case let .code(_, text):
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(text).font(.callout.monospaced()).padding(8)
                    }
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }
}
