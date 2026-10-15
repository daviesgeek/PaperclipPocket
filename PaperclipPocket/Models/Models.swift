import Foundation

struct Company: Codable, Identifiable, Hashable {
    let id: String
    let name: String
}

struct Agent: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let role: String?
    let title: String?
    let status: String?
    var avatarUrl: String? = nil
    var appearance: Appearance? = nil

    struct Appearance: Codable, Hashable {
        let characterVersion: String?
        let paletteId: String?
    }
}

struct LiveEvent: Sendable {
    let type: String
    let agentId: String?
    let issueId: String?
    let text: String?

    /// Synthetic event emitted when the socket reconnects, so consumers can resync missed updates.
    static let reconnectType = "stream.reconnected"

    init(type: String) {
        self.type = type
        agentId = nil
        issueId = nil
        text = nil
    }

    init?(data: Data) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = root["type"] as? String else { return nil }
        let payload = root["payload"] as? [String: Any] ?? [:]
        func string(_ keys: [String]) -> String? {
            for key in keys {
                if let value = payload[key] as? String, !value.isEmpty { return value }
            }
            return nil
        }
        self.type = type
        agentId = string(["agentId"])
        issueId = string(["issueId", "contextIssueId"])
            ?? (root["entityType"] as? String == "issue" ? root["entityId"] as? String : nil)
        text = string(["message", "chunk", "summary", "status"])
    }
}

struct Issue: Codable, Identifiable, Hashable {
    let id: String
    let identifier: String?
    let title: String
    let description: String?
    let status: Status
    let priority: String?
    let assigneeAgentId: String?
    let conversationAgentId: String?
    let conversationState: String?
    let updatedAt: String?
    let isUnreadForMe: Bool?
    let projectId: String?

    let blockerAttention: BlockerAttention?
}

struct BlockerAttention: Codable, Hashable {
    let state: String
    let attentionBlockerCount: Int
}

struct IssueComment: Codable, Identifiable, Hashable {
    let id: String
    let body: String
    let authorAgentId: String?
    let authorUserId: String?
    let createdAt: String?

    var isAgentReply: Bool { authorAgentId != nil }
}

struct IssueAttachment: Codable, Identifiable, Hashable {
    let id: String
    let originalFilename: String?
    let contentType: String?
    let issueCommentId: String?
}

struct PendingAttachment: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let mimeType: String
    let data: Data
}

struct AppConfiguration: Codable, Equatable {
    var paperclipURL: String = ""
    var boardToken: String = ""
    var companyID: String = ""
    var pushRelayURL: String = ""
    var pushRelaySecret: String = ""

    var isReady: Bool {
        !paperclipURL.isEmpty && !boardToken.isEmpty && !companyID.isEmpty
    }
}

struct ChatRoute: Hashable {
    let agent: Agent
    let issueID: String?
}

extension String {
    var readableStatus: String {
        replacingOccurrences(of: "_", with: " ").capitalized
    }
}

struct Project: Codable, Identifiable, Hashable {
  let id: String
  let name: String
}

enum Status: String, Codable, CaseIterable {
    case backlog
    case todo
    case in_progress
    case in_review
    case blocked
    case done
    case cancelled
}
