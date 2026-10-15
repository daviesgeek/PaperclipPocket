import SwiftUI
import SafariServices

// Paperclip's existing CLI authorization challenge is also suitable for mobile
// clients. The pending board token must NEVER be used or stored before approval.
private struct PaperclipLoginChallenge: Decodable {
    let id: String
    let token: String
    let boardApiToken: String
    let approvalPath: String
    let suggestedPollIntervalMs: Int
}

private struct PaperclipLoginStatus: Decodable {
    let status: String
}

private struct PaperclipIdentity: Decodable {
    struct User: Decodable {
        let name: String?
        let email: String?
    }
    let user: User?
}

private struct PaperclipLoginPage: Identifiable {
    let id = UUID()
    let url: URL
}

private struct PaperclipLoginBrowser: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

private enum PaperclipLoginError: LocalizedError {
    case invalidURL
    case invalidServerResponse
    case server(Int, String)
    case cancelled
    case expired

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Enter a valid HTTPS Paperclip server URL."
        case .invalidServerResponse:
            return "Unexpected login response from Paperclip. Check its version."
        case let .server(code, text):
            return "Paperclip login error \(code): \(text)"
        case .cancelled:
            return "Authorization was cancelled. You can try again."
        case .expired:
            return "Authorization expired. Tap Sign in to try again."
        }
    }
}

private enum PaperclipBrowserAuth {
    static func origin(_ string: String) throws -> URL {
        let raw = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: raw),
              url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/"
        else { throw PaperclipLoginError.invalidURL }
        return url
    }

    private static func endpoint(_ origin: URL, _ path: String, query: [URLQueryItem] = []) -> URL {
        var components = URLComponents(url: origin, resolvingAgainstBaseURL: false)!
        components.path = path
        components.queryItems = query.isEmpty ? nil : query
        return components.url!
    }

    private static func response<T: Decodable>(_ request: URLRequest, as type: T.Type) async throws -> T {
        let (data, result) = try await URLSession.shared.data(for: request)
        guard let http = result as? HTTPURLResponse else { throw PaperclipLoginError.invalidServerResponse }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Request failed"
            throw PaperclipLoginError.server(http.statusCode, String(message.prefix(180)))
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw PaperclipLoginError.invalidServerResponse
        }
    }

    static func createChallenge(at origin: URL) async throws -> PaperclipLoginChallenge {
        var request = URLRequest(url: endpoint(origin, "/api/cli-auth/challenges"))
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "command": "paperclip-pocket-ios",
            "clientName": "Paperclip Pocket for iOS",
            "requestedAccess": "board"
        ])
        return try await response(request, as: PaperclipLoginChallenge.self)
    }

    static func approvalURL(at origin: URL, for challenge: PaperclipLoginChallenge) throws -> URL {
        // Use the user-entered HTTPS origin, not a possible internal HTTP origin
        // reconstructed from reverse-proxy headers by the Paperclip server.
        guard challenge.approvalPath.hasPrefix("/cli-auth/"),
              let components = URLComponents(string: challenge.approvalPath),
              components.host == nil,
              let url = URL(string: challenge.approvalPath, relativeTo: origin)?.absoluteURL,
              url.host == origin.host, url.scheme == "https"
        else { throw PaperclipLoginError.invalidServerResponse }
        return url
    }

    static func status(at origin: URL, for challenge: PaperclipLoginChallenge) async throws -> PaperclipLoginStatus {
        let url = endpoint(origin, "/api/cli-auth/challenges/\(challenge.id)", query: [
            URLQueryItem(name: "token", value: challenge.token)
        ])
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        return try await response(request, as: PaperclipLoginStatus.self)
    }

    static func verify(at origin: URL, boardToken: String) async throws -> PaperclipIdentity {
        var request = URLRequest(url: endpoint(origin, "/api/cli-auth/me"))
        request.timeoutInterval = 20
        request.setValue("Bearer \(boardToken)", forHTTPHeaderField: "Authorization")
        return try await response(request, as: PaperclipIdentity.self)
    }

    static func revoke(at origin: URL, boardToken: String) async throws {
        var request = URLRequest(url: endpoint(origin, "/api/cli-auth/revoke-current"))
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("Bearer \(boardToken)", forHTTPHeaderField: "Authorization")
        let (_, result) = try await URLSession.shared.data(for: request)
        guard let http = result as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw PaperclipLoginError.invalidServerResponse
        }
    }
}

@MainActor
struct SettingsView: View {
    @EnvironmentObject private var store: AppStore

    @State private var config = AppConfiguration()
    @State private var companies: [Company] = []
    @State private var statusText: String?
    @State private var validating = false
    @State private var signingIn = false
    @State private var browserPage: PaperclipLoginPage?
    @State private var approvalURL: URL?
    @State private var loginTask: Task<Void, Never>?
    @State private var identity: String?
    @State private var showManualToken = false

    var body: some View {
        NavigationStack {
            Form {
                accountSection
                manualLoginSection
                pushSection
                actionsSection
            }
            .navigationTitle(config.boardToken.isEmpty ? "Connect Paperclip" : "Settings")
            .sheet(item: $browserPage) { page in
                PaperclipLoginBrowser(url: page.url)
                    .ignoresSafeArea()
            }
            .onAppear(perform: loadSavedConfiguration)
        }
    }

    // Each section has its own view-builder boundary, avoiding a single giant
    // SwiftUI expression that Xcode may fail to type-check.
    private var accountSection: some View {
        Section {
            TextField("https://paperclip.example.com", text: $config.paperclipURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .textContentType(.URL)

            connectionSummary
            signInButton
            approvalControls
            companySelection
            accountActions
        } header: {
            Text("Paperclip account")
        } footer: {
            Text("Sign in through your Paperclip server. The approved credential is saved in iOS Keychain. Use HTTPS and a trusted server.")
        }
    }

    @ViewBuilder
    private var connectionSummary: some View {
        if !config.boardToken.isEmpty {
            Label("Connected to Paperclip", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
            if let identity {
                Text(identity)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var signInButton: some View {
        Button(action: beginSignIn) {
            HStack {
                Label(
                    config.boardToken.isEmpty ? "Sign in with Paperclip" : "Reconnect Paperclip",
                    systemImage: "lock.shield"
                )
                if signingIn {
                    Spacer()
                    ProgressView()
                }
            }
        }
        .disabled(signingIn || config.paperclipURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @ViewBuilder
    private var approvalControls: some View {
        if signingIn, let approvalURL {
            Button("Return to approval page") {
                browserPage = PaperclipLoginPage(url: approvalURL)
            }
            Button("Cancel sign in", role: .cancel, action: cancelSignIn)
        }
    }

    @ViewBuilder
    private var companySelection: some View {
        if !companies.isEmpty {
            Picker("Company", selection: $config.companyID) {
                Text("Choose company").tag("")
                ForEach(companies) { company in
                    Text(company.name).tag(company.id)
                }
            }
        } else if !config.boardToken.isEmpty {
            TextField("Company ID (UUID)", text: $config.companyID)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
    }

    @ViewBuilder
    private var accountActions: some View {
        if !config.boardToken.isEmpty {
            Button(validating ? "Loading companies…" : "Refresh companies") {
                Task { await findCompanies() }
            }
            .disabled(validating)

            Button("Disconnect Paperclip", role: .destructive) {
                Task { await disconnect() }
            }
            .disabled(signingIn)
        }
    }

    private var manualLoginSection: some View {
        Section("Advanced login") {
            DisclosureGroup("Use an existing API token instead", isExpanded: $showManualToken) {
                SecureField("Board API token", text: $config.boardToken)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Connect with token") {
                    Task { await findCompanies() }
                }
                .disabled(validating || config.boardToken.isEmpty || config.paperclipURL.isEmpty)
            }
        }
    }

    private var pushSection: some View {
        Section {
            TextField("https://push.example.com", text: $config.pushRelayURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            SecureField("Push relay shared secret", text: $config.pushRelaySecret)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        } header: {
            Text("Push notifications (optional)")
        } footer: {
            Text("The relay runs separately and needs APNs credentials. Your Paperclip token is not sent to it.")
        }
    }

    private var actionsSection: some View {
        Section {
            Button("Save settings", action: saveSettings)
                .disabled(!config.isReady)
            Button("Enable notifications", action: enableNotifications)
                .disabled(!config.isReady || config.pushRelayURL.isEmpty || config.pushRelaySecret.isEmpty)

            Text("Push: \(store.pushStatus)")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let statusText {
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func loadSavedConfiguration() {
        config = store.configuration
        if !config.boardToken.isEmpty, companies.isEmpty {
            Task { await findCompanies(persist: false) }
        }
    }

    private func beginSignIn() {
        loginTask?.cancel()
        loginTask = Task { await signIn() }
    }

    private func cancelSignIn() {
        loginTask?.cancel()
        loginTask = nil
        signingIn = false
        browserPage = nil
        approvalURL = nil
        statusText = "Sign in cancelled."
    }

    private func saveSettings() {
        do {
            try store.save(config)
            statusText = "Saved"
        } catch {
            statusText = error.localizedDescription
        }
    }

    private func enableNotifications() {
        do {
            try store.save(config)
            Task { await store.requestNotifications() }
        } catch {
            statusText = error.localizedDescription
        }
    }

    private func signIn() async {
        signingIn = true
        statusText = "Opening secure Paperclip approval…"
        defer {
            signingIn = false
            loginTask = nil
        }

        do {
            let origin = try PaperclipBrowserAuth.origin(config.paperclipURL)
            let challenge = try await PaperclipBrowserAuth.createChallenge(at: origin)
            try Task.checkCancellation()

            let url = try PaperclipBrowserAuth.approvalURL(at: origin, for: challenge)
            approvalURL = url
            browserPage = PaperclipLoginPage(url: url)
            statusText = "Sign in and approve access in the Paperclip browser page."

            let interval = UInt64(max(1_000, min(challenge.suggestedPollIntervalMs, 5_000))) * 1_000_000
            var approved = false
            for _ in 0..<300 {
                try Task.checkCancellation()
                let result = try await PaperclipBrowserAuth.status(at: origin, for: challenge)
                switch result.status {
                case "approved": approved = true
                case "cancelled": throw PaperclipLoginError.cancelled
                case "expired": throw PaperclipLoginError.expired
                default: break
                }
                if approved { break }
                try await Task.sleep(nanoseconds: interval)
            }
            guard approved else { throw PaperclipLoginError.expired }

            let who = try await PaperclipBrowserAuth.verify(at: origin, boardToken: challenge.boardApiToken)
            try Task.checkCancellation()

            browserPage = nil
            approvalURL = nil
            identity = who.user?.name ?? who.user?.email
            config.boardToken = challenge.boardApiToken

            do {
                companies = try await PaperclipAPI(configuration: config).companies()
                if !companies.contains(where: { $0.id == config.companyID }) {
                    config.companyID = companies.first?.id ?? ""
                }
                statusText = companies.isEmpty
                    ? "Signed in. No accessible companies were found."
                    : "Signed in successfully. Choose a company if needed."
            } catch {
                // Retain the approved token if company discovery fails temporarily.
                config.companyID = ""
                companies = []
                statusText = "Signed in, but could not load companies: \(error.localizedDescription)"
            }
            try Task.checkCancellation()
            try store.save(config)
        } catch is CancellationError {
            browserPage = nil
            approvalURL = nil
            statusText = "Sign in cancelled."
        } catch {
            browserPage = nil
            approvalURL = nil
            statusText = error.localizedDescription
        }
    }

    private func findCompanies(persist: Bool = true) async {
        guard !validating else { return }
        validating = true
        defer { validating = false }
        do {
            let response = try await PaperclipAPI(configuration: config).companies()
            companies = response
            if !response.contains(where: { $0.id == config.companyID }) {
                config.companyID = response.first?.id ?? ""
            }
            if persist { try store.save(config) }
            statusText = response.isEmpty ? "No companies found." : "Connected"
        } catch {
            statusText = error.localizedDescription
        }
    }

    private func disconnect() async {
        cancelSignIn()
        if !config.boardToken.isEmpty,
           let origin = try? PaperclipBrowserAuth.origin(config.paperclipURL) {
            // Best-effort revocation before dropping the local credential.
            try? await PaperclipBrowserAuth.revoke(at: origin, boardToken: config.boardToken)
        }
        config.boardToken = ""
        config.companyID = ""
        identity = nil
        companies = []
        do {
            try store.save(config)
            statusText = "Disconnected. Unregister from the push relay separately if needed."
        } catch {
            statusText = error.localizedDescription
        }
    }
}
