import Foundation
import SwiftUI
import UserNotifications
import UIKit

@MainActor
final class AppStore: ObservableObject {
    static let shared = AppStore()

    @Published private(set) var configuration = KeychainStorage.load()
    @Published var selectedTab = 2
    @Published var requestedChatIssueID: String?
    @Published var pushStatus = "Not configured"

    private(set) var deviceToken: String?
    private var sessions: [String: ThreadSession] = [:]

    private init() {
        if configuration.isReady { selectedTab = 0 }
    }

    var api: PaperclipAPI { PaperclipAPI(configuration: configuration) }

    /// Thread state outlives its view, so leaving a conversation and returning resumes instantly.
    func session(key: String, issueID: String?, agentID: String?, isChat: Bool) -> ThreadSession {
        if let existing = sessions[key] {
            existing.adopt(issueID: issueID, agentID: agentID)
            return existing
        }
        let created = ThreadSession(issueID: issueID, agentID: agentID, isChat: isChat)
        sessions[key] = created
        return created
    }

    func save(_ newConfiguration: AppConfiguration) throws {
        var trimmed = newConfiguration
        trimmed.paperclipURL = trimmed.paperclipURL.trimmingCharacters(in: .whitespacesAndNewlines)
        trimmed.boardToken = trimmed.boardToken.trimmingCharacters(in: .whitespacesAndNewlines)
        trimmed.companyID = trimmed.companyID.trimmingCharacters(in: .whitespacesAndNewlines)
        trimmed.pushRelayURL = trimmed.pushRelayURL.trimmingCharacters(in: .whitespacesAndNewlines)
        trimmed.pushRelaySecret = trimmed.pushRelaySecret.trimmingCharacters(in: .whitespacesAndNewlines)
        try KeychainStorage.save(trimmed)
        if trimmed.paperclipURL != configuration.paperclipURL || trimmed.companyID != configuration.companyID {
            sessions.removeAll()
        }
        let wasReady = configuration.isReady
        configuration = trimmed
        if trimmed.isReady && !wasReady { selectedTab = 0 }
        if deviceToken != nil { Task { await registerDevice() } }
    }

    func requestNotifications() async {
        guard !configuration.pushRelayURL.isEmpty && !configuration.pushRelaySecret.isEmpty else {
            pushStatus = "Set a push relay URL and secret first."
            return
        }
        do {
            let accepted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .badge, .sound])
            if accepted {
                UIApplication.shared.registerForRemoteNotifications()
                pushStatus = "Registering with Apple…"
                if deviceToken != nil { await registerDevice() }
            } else {
                pushStatus = "Notification permission was declined. Enable it in iOS Settings."
            }
        } catch {
            pushStatus = error.localizedDescription
        }
    }

    func receiveDeviceToken(_ token: Data) async {
        deviceToken = token.map { String(format: "%02x", $0) }.joined()
        await registerDevice()
    }

    func registerDevice() async {
        guard let deviceToken,
              let url = URL(string: configuration.pushRelayURL),
              url.scheme == "https", !configuration.pushRelaySecret.isEmpty,
              !configuration.companyID.isEmpty
        else {
            pushStatus = "Push relay requires HTTPS, a shared secret, and a company ID."
            return
        }
        do {
            var request = URLRequest(url: url.appendingPathComponent("register"))
            request.httpMethod = "POST"
            request.timeoutInterval = 20
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(configuration.pushRelaySecret)", forHTTPHeaderField: "Authorization")
            request.httpBody = try JSONEncoder().encode(["deviceToken": deviceToken, "companyId": configuration.companyID])
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                let detail = String(data: data, encoding: .utf8)?.prefix(100) ?? ""
                throw NSError(domain: "Push relay", code: code, userInfo: [NSLocalizedDescriptionKey: "Relay returned HTTP \(code) \(detail). Check the relay URL, secret, and company ID."])
            }
            // A proxy or SPA catch-all can return 2xx without being the relay.
            guard (try? JSONDecoder().decode([String: Bool].self, from: data))?["ok"] == true else {
                throw NSError(domain: "Push relay", code: 2, userInfo: [NSLocalizedDescriptionKey: "That URL answered but is not the push relay. Check the relay URL."])
            }
            pushStatus = "Notifications enabled"
        } catch {
            pushStatus = error.localizedDescription
        }
    }

    func openNotification(issueID: String) {
        requestedChatIssueID = issueID
        selectedTab = 1
    }
}

final class NotificationDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        application.registerForRemoteNotifications()
        return true
    }

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in await AppStore.shared.receiveDeviceToken(deviceToken) }
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Task { @MainActor in AppStore.shared.pushStatus = error.localizedDescription }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let issueID = response.notification.request.content.userInfo["chatIssueId"] as? String {
            Task { @MainActor in AppStore.shared.openNotification(issueID: issueID) }
        }
        completionHandler()
    }
}
