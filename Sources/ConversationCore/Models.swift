import Foundation

public struct ChatMessage: Codable, Identifiable, Sendable {
    public var id: String
    public var role: String
    public var text: String
    public var timestamp: String
    public var tools: [ToolRecord]
    public var images: [ChatImage]
}

public struct ToolRecord: Codable, Sendable {
    public var name: String
    public var text: String
}

public struct ChatImage: Codable, Sendable {
    public var path: String
    public var mediaType: String
    public var data: Data?
}

public struct Conversation: Identifiable, Sendable {
    public var id: String { sourceURL.path }
    public var sessionID: String
    public var title: String
    public var project: String
    public var projectPath: String
    public var sourceURL: URL
    public var modified: Date
    public var messages: [ChatMessage]
    public var imported: Bool
    public var malformedLines: Int
    public var searchText: String
    public var messageCount: Int { messages.filter { !$0.text.isEmpty || !$0.images.isEmpty }.count }
}

public struct ScanResult: Sendable {
    public var conversations: [Conversation]
    public var warnings: [String]
}

public enum ConversationError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? {
        switch self { case .invalid(let message): return message }
    }
}
