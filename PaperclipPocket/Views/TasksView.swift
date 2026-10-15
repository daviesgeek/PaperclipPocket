import SwiftUI

struct TasksView: View {
    @EnvironmentObject private var store: AppStore
    @State private var issues: [Issue] = []
    @State private var agents: [Agent] = []
    @State private var projects: [Project] = []
    @State private var error: String?
    @State private var loading = false
    @State private var query = ""
    @State private var searchDebounceTask: Task<Void, Never>?
    @State private var showFilters = false
    private static let defaultStatuses: [Status] = [.backlog, .todo, .in_progress, .in_review, .blocked]

    @AppStorage("tasks.statusFilter") private var statusStorage = TasksView.defaultStatuses.map(\.rawValue).joined(separator: ",")
    @AppStorage("tasks.projectFilter") private var projectFilter = ""
    @AppStorage("tasks.agentFilter") private var agentFilter = ""

    private var status: [Status] {
        get { statusStorage.split(separator: ",").compactMap { Status(rawValue: String($0)) } }
        nonmutating set { statusStorage = newValue.map(\.rawValue).joined(separator: ",") }
    }

    private var hasFilters: Bool {
        Set(status) != Set(Self.defaultStatuses) || !projectFilter.isEmpty || !agentFilter.isEmpty
    }

    private var filterPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Status").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(Status.allCases, id: \.self) { option in
                    let selected = status.contains(option)
                    Button {
                        if selected { status.removeAll { $0 == option } } else { status.append(option) }
                    } label: {
                        Text(option.rawValue.readableStatus)
                            .font(.caption.weight(.medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(selected ? Color.accentColor : Color(.tertiarySystemFill), in: Capsule())
                            .foregroundStyle(selected ? Color.white : Color.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            LabeledContent("Project") {
                Picker("Project", selection: $projectFilter) {
                    Text("All").tag("")
                    ForEach(projects) { Text($0.name).tag($0.id) }
                }
                .labelsHidden()
            }
            LabeledContent("Agent") {
                Picker("Agent", selection: $agentFilter) {
                    Text("All").tag("")
                    ForEach(agents) { Text($0.name).tag($0.id) }
                }
                .labelsHidden()
            }
            if hasFilters {
                Button("Reset Filters", systemImage: "arrow.counterclockwise", role: .destructive) {
                    status = Self.defaultStatuses
                    projectFilter = ""
                    agentFilter = ""
                }
                .font(.subheadline)
            }
        }
        .padding()
        .frame(minWidth: 300)
        .presentationCompactAdaptation(.popover)
    }

    private let previewMode: Bool

    init(previewIssues: [Issue]? = nil, previewAgents: [Agent]? = nil, previewProjects: [Project]? = nil) {
        self._issues = State(initialValue: previewIssues ?? [])
        self._agents = State(initialValue: previewAgents ?? [])
        self._projects = State(initialValue: previewProjects ?? [])
        self.previewMode = (previewIssues != nil) || (previewAgents != nil) || (previewProjects != nil)
    }

    var body: some View {
        NavigationStack {
            Group {
                if previewMode {
                    if issues.isEmpty {
                        ContentUnavailableView("No tasks", systemImage: "checklist",
                                               description: Text("Tasks will appear here."))
                    } else {
                        taskList
                    }
                } else if !store.configuration.isReady {
                    ContentUnavailableView("Connect Paperclip", systemImage: "link",
                                           description: Text("Sign in to your Paperclip server in Settings."))
                } else if loading && issues.isEmpty {
                    ProgressView("Loading tasks…")
                } else if let error, issues.isEmpty {
                    ContentUnavailableView("Could not load tasks", systemImage: "wifi.exclamationmark",
                                           description: Text(error))
                } else if issues.isEmpty {
                    ContentUnavailableView("No tasks", systemImage: "checklist",
                                           description: Text("Tasks will appear here."))
                } else {
                    taskList
                }
            }
            .navigationTitle("Tasks")
            .searchable(text: $query, prompt: "Search tasks")
            .onSubmit(of: .search) { Task { await load() } }
            .onChange(of: query) { _, newValue in
                searchDebounceTask?.cancel()
                if newValue.isEmpty {
                    searchDebounceTask = Task { await load() }
                } else {
                    searchDebounceTask = Task { @MainActor in
                        do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
                        await load()
                    }
                }
            }
            .toolbar {
                Button { showFilters = true } label: {
                    Image(systemName: "line.3.horizontal.decrease")
                        .symbolVariant(hasFilters ? .circle.fill : .none)
                }
                .disabled(!store.configuration.isReady)
                .accessibilityLabel("Filter tasks")
                .popover(isPresented: $showFilters) { filterPanel }
                Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(!store.configuration.isReady || loading)
            }
            .onChange(of: status) { _, _ in Task { await load() } }
            .onChange(of: projectFilter) { _, _ in Task { await load() } }
            .onChange(of: agentFilter) { _, _ in Task { await load() } }
            .task(id: store.configuration) { if !previewMode { await load() } }
        }
    }

    private var taskList: some View {
        List {
            if loading && !query.isEmpty {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Searching…").foregroundStyle(.secondary)
                }
            }
            ForEach(issues) { issue in
                let project = projects.first { $0.id == issue.projectId }
                let agent = agents.first { $0.id == issue.assigneeAgentId }
                NavigationLink {
                    TaskDetailView(issueID: issue.id)
                } label: {
                    IssueRow(identifier: issue.identifier, title: issue.title, projectName: project?.name,
                             status: issue.status.rawValue, isUnread: issue.isUnreadForMe ?? false, agent: agent)
                }
            }
        }
        .refreshable { await load() }
    }

    @MainActor
    private func load() async {
        guard store.configuration.isReady else { issues = []; projects = []; return }
        loading = true
        defer { loading = false }
        do {
            var queryParams: [URLQueryItem] = [URLQueryItem(name: "touchedByUserId", value: "me")]
            if !status.isEmpty {
                queryParams.append(URLQueryItem(name: "status", value: status.map(\.rawValue).joined(separator: ",")))
            }
            if !projectFilter.isEmpty { queryParams.append(URLQueryItem(name: "projectId", value: projectFilter)) }
            if !agentFilter.isEmpty { queryParams.append(URLQueryItem(name: "assigneeAgentId", value: agentFilter)) }
            if !query.isEmpty { queryParams.append(URLQueryItem(name: "q", value: query)) }
            async let taskResponse = store.api.issues(queryParams)
            async let agentResponse = store.api.agents()
            async let projectResponse = store.api.projects()
            let (all, roster, projectList) = try await (taskResponse, agentResponse, projectResponse)
            issues = all.filter { $0.conversationAgentId == nil }
            agents = roster
            projects = projectList
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}

struct StatusLabel: View {
    let status: String
    private var title: String { status.readableStatus }

    private var color: Color {
        switch title {
        case "In Progress": .blue
        case "Todo": .orange
        case "In Review": .purple
        case "Blocked": .red
        case "Done": .green
        case "Backlog", "Cancelled": .secondary
        default: .secondary
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            StatusIcon(title: title, color: color).frame(width: 16, height: 16)
            Text(title).font(.caption.weight(.medium)).foregroundStyle(color)
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

private struct StatusIcon: View {
    let title: String
    let color: Color

    var body: some View {
        switch title {
        case "In Progress":
            Circle().trim(from: 0.08, to: 0.72)
                .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        case "Todo":
            Image(systemName: "circle").font(.system(size: 15)).foregroundStyle(color)
        case "Backlog":
            Image(systemName: "circle.dashed").font(.system(size: 15, weight: .medium)).foregroundStyle(color)
        case "In Review":
            ZStack { Circle().stroke(color, lineWidth: 2); Circle().fill(color).frame(width: 4, height: 4) }
                .padding(1)
        case "Blocked":
            Image(systemName: "minus.circle").font(.system(size: 15)).foregroundStyle(color)
        case "Done":
            Image(systemName: "checkmark.circle").font(.system(size: 15)).foregroundStyle(color)
        case "Cancelled":
            Image(systemName: "nosign").font(.system(size: 15)).foregroundStyle(color)
        default:
            Image(systemName: "circle").font(.system(size: 15)).foregroundStyle(color)
        }
    }
}

struct ProjectLabel: View {
    let name: String
    var body: some View {
        Text(name).font(.caption2.weight(.medium)).padding(.horizontal, 8).padding(.vertical, 4)
            .background(.quaternary, in: Capsule()).foregroundStyle(.secondary)
    }
}

private struct IssueRow: View {
    let identifier: String?
    let title: String
    let projectName: String?
    let status: String
    let isUnread: Bool
    let agent: Agent?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if let identifier { Text(identifier).font(.caption.monospaced()).foregroundStyle(.secondary) }
                Spacer()
                if let projectName { ProjectLabel(name: projectName) }
                StatusLabel(status: status)
                if isUnread { Circle().fill(.blue).frame(width: 4, height: 4) }
            }
            Text(title).font(.body.weight(.medium))
            if let agent {
                HStack(spacing: 6) { AgentAvatar(agent: agent, size: 20); Text(agent.name) }
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

struct TaskDetailView: View {
    @EnvironmentObject private var store: AppStore
    let issueID: String

    var body: some View {
        TaskThreadView(issueID: issueID,
                       session: store.session(key: "task:\(issueID)", issueID: issueID, agentID: nil, isChat: false))
    }
}

private struct TaskThreadView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.scenePhase) private var scenePhase
    let issueID: String
    @ObservedObject var session: ThreadSession
    @State private var issue: Issue?
    @State private var agents: [Agent] = []
    @State private var projects: [Project] = []
    @State private var error: String?
    @State private var titleDraft = ""
    @State private var descriptionDraft = ""
    @State private var saving = false
    @State private var composerFocused = false
    private let priorityOptions = ["urgent", "high", "medium", "low", "none"]

    var body: some View {
        Group {
            if let issue {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            taskProperties(issue)
                            Divider().padding(.vertical, 4)
                            if session.comments.isEmpty && session.activityText == nil && !session.transcript.hasRun {
                                Text("No comments yet").font(.subheadline).foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 24)
                            }
                            ForEach(session.comments) { comment in
                                commentRow(comment)
                            }
                            if session.transcript.hasRun { RunActivityView(run: session.transcript).id("run") }
                            if let activity = session.activityText { AgentActivityRow(text: activity).id("activity") }
                            if let message = error ?? session.error { Text(message).font(.caption).foregroundStyle(.red) }
                        }
                        .padding()
                    }
                    .defaultScrollAnchor(.top)
                    .onChange(of: session.comments.last?.id) { _, id in
                        if let id { withAnimation { proxy.scrollTo(id, anchor: .bottom) } }
                    }
                    .onChange(of: session.activityText) { _, value in
                        if value != nil { withAnimation { proxy.scrollTo("activity", anchor: .bottom) } }
                    }
                    .onChange(of: session.transcript.entries.count) { _, _ in
                        if session.transcript.isRunning { proxy.scrollTo("run", anchor: .bottom) }
                    }
                }
            } else if let error {
                ContentUnavailableView("Could not load task", systemImage: "wifi.exclamationmark", description: Text(error))
            } else {
                ProgressView("Loading task…")
            }
        }
        .background(Color(.systemGroupedBackground))
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if issue != nil {
                IssueCommentComposer(draft: $session.draft, pendingFiles: $session.pendingFiles, isFocused: $composerFocused,
                                     sending: session.sending, placeholder: "Add a comment…",
                                     onSend: { composerFocused = false; Task { await session.send(api: store.api) } },
                                     onError: { session.error = $0 })
            }
        }
        .navigationTitle(issue?.identifier ?? "Task")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task {
            session.onRefresh = { await reloadIssue() }
            await load()
        }
        .task { await session.listen(api: store.api) }
        .task { await session.poll(api: store.api) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await session.refresh(api: store.api) } }
        }
    }

    private func taskProperties(_ issue: Issue) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if let identifier = issue.identifier { Text(identifier).font(.caption.monospaced()).foregroundStyle(.secondary) }
            HStack(alignment: .top, spacing: 8) {
                TextField("Task title", text: $titleDraft, axis: .vertical)
                    .font(.title3.weight(.semibold)).textFieldStyle(.plain)
                if titleDraft != issue.title {
                    Button { Task { await saveFields(["title": titleDraft], updateTitle: true) } } label: {
                        Image(systemName: "checkmark.circle.fill")
                    }
                    .disabled(saving || titleDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel("Save task title")
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                TextEditor(text: $descriptionDraft).frame(minHeight: descriptionDraft.isEmpty ? 44 : 78)
                    .scrollContentBackground(.hidden)
                    .overlay(alignment: .topLeading) {
                        if descriptionDraft.isEmpty {
                            Text("Add a description…").foregroundStyle(.tertiary)
                                .padding(.horizontal, 5).padding(.vertical, 8).allowsHitTesting(false)
                        }
                    }
                    .padding(8).background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
                if descriptionDraft != (issue.description ?? "") {
                    HStack {
                        Spacer()
                        Button("Save description", systemImage: "checkmark") {
                            let value: Any = descriptionDraft.isEmpty ? NSNull() : descriptionDraft
                            Task { await saveFields(["description": value], updateDescription: true) }
                        }
                        .disabled(saving)
                    }
                    .font(.caption)
                }
            }
            VStack(spacing: 8) {
                propertyPicker("Status", selection: Binding(
                    get: { issue.status }, set: { value in Task { await saveFields(["status": value.rawValue]) } }
                )) {
                    ForEach(Status.allCases, id: \.self) { value in Text(value.rawValue.readableStatus).tag(value) }
                }
                propertyPicker("Priority", selection: Binding(
                    get: { issue.priority ?? "none" },
                    set: { value in
                        let priority: Any = value == "none" ? NSNull() : value
                        Task { await saveFields(["priority": priority]) }
                    }
                )) {
                    ForEach(priorityOptions, id: \.self) { value in
                        Text(value == "none" ? "None" : value.readableStatus).tag(value)
                    }
                    if let priority = issue.priority, !priorityOptions.contains(priority) {
                        Text(priority.readableStatus).tag(priority)
                    }
                }
                propertyPicker("Assignee", selection: Binding(
                    get: { issue.assigneeAgentId ?? "" },
                    set: { value in
                        let agentID: Any = value.isEmpty ? NSNull() : value
                        Task { await saveFields(["assigneeAgentId": agentID]) }
                    }
                )) {
                    Text("Unassigned").tag("")
                    ForEach(agents) { agent in Text(agent.name).tag(agent.id) }
                }
                propertyPicker("Project", selection: Binding(
                    get: { issue.projectId ?? "" },
                    set: { value in
                        let projectID: Any = value.isEmpty ? NSNull() : value
                        Task { await saveFields(["projectId": projectID]) }
                    }
                )) {
                    Text("No project").tag("")
                    ForEach(projects) { project in Text(project.name).tag(project.id) }
                }
            }
            if saving { ProgressView().controlSize(.small) }
        }
    }

    private func propertyPicker<Selection: Hashable, Options: View>(
        _ title: String, selection: Binding<Selection>, @ViewBuilder options: () -> Options
    ) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Picker(title, selection: selection, content: options).labelsHidden().tint(.primary).disabled(saving)
        }
        .font(.subheadline)
    }

    @MainActor
    private func saveFields(_ fields: [String: Any], updateTitle: Bool = false, updateDescription: Bool = false) async {
        guard !saving else { return }
        saving = true
        defer { saving = false }
        do {
            let updated = try await store.api.updateIssue(issueID, fields: fields)
            issue = updated
            if updateTitle { titleDraft = updated.title }
            if updateDescription { descriptionDraft = updated.description ?? "" }
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    @MainActor
    private func commentRow(_ comment: IssueComment) -> some View {
        let author = agents.first { $0.id == comment.authorAgentId }
        let commentFiles = session.attachments.filter { $0.issueCommentId == comment.id }
        return IssueCommentBubble(comment: comment, authorName: author?.name, attachments: commentFiles)
            .id(comment.id)
    }
    /// Applies a freshly fetched issue; title/description drafts only seed on first load.
    private func apply(_ loaded: Issue) {
        if issue == nil {
            titleDraft = loaded.title
            descriptionDraft = loaded.description ?? ""
        }
        issue = loaded
        session.agentID = loaded.assigneeAgentId
    }

    @MainActor
    private func reloadIssue() async {
        if let loaded = try? await store.api.issue(issueID) { apply(loaded) }
    }

    @MainActor
    private func load() async {
        do {
            async let detail = store.api.issue(issueID)
            async let roster = store.api.agents()
            async let projectList = store.api.projects()
            let (loadedIssue, loadedAgents, loadedProjects) = try await (detail, roster, projectList)
            apply(loadedIssue)
            agents = loadedAgents
            projects = loadedProjects
            error = nil
        } catch { self.error = error.localizedDescription }
        await session.refresh(api: store.api)
    }
}
