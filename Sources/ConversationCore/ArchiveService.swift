import Foundation
import CryptoKit

public struct ArchiveManifest: Codable, Sendable {
    public var format: String
    public var version: Int
    public var createdAt: Date
    public var conversations: [ArchiveEntry]
}

public struct ArchiveEntry: Codable, Sendable {
    public var file: String
    public var title: String
    public var projectPath: String
    public var modified: Date
}

public struct ExportReport: Sendable {
    public var conversations: Int
    public var attachments: Int
    public var missingAttachments: Int
}

public enum ArchiveService {
    // Keep the original format identifier for compatibility with existing v1 archives.
    public static func attachmentName(for path: String) -> String {
        let digest = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
        let suffix = URL(fileURLWithPath: path).pathExtension.filter { $0.isLetter || $0.isNumber }
        return digest + (suffix.isEmpty ? "" : "." + suffix)
    }

    public static func export(_ conversations: [Conversation], to destination: URL) throws -> ExportReport {
        guard !conversations.isEmpty else { throw ConversationError.invalid("Choose at least one conversation to export.") }
        var files: [String: Data] = [:]
        var entries: [ArchiveEntry] = []
        var missing = Set<String>(), included = Set<String>()
        for (index, conversation) in conversations.enumerated() {
            let name = "sessions/\(index)-\(conversation.sessionID).jsonl"
            files[name] = try Data(contentsOf: conversation.sourceURL)
            entries.append(ArchiveEntry(file: name, title: conversation.title,
                projectPath: conversation.projectPath, modified: conversation.modified))
            // Keep original JSONL bytes, including all metadata, tool logs and embedded images.
            // External image references are copied separately where the original file still exists.
            let raw = String(data: files[name]!, encoding: .utf8) ?? ""
            // Decode text before looking for image paths: JSON permits escaped slashes.
            var textParts: [String] = []
            for line in raw.split(separator: "\n") {
                guard let bytes = line.data(using: .utf8),
                      let record = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any],
                      let message = record["message"] as? [String: Any] else { continue }
                if let content = message["content"] as? String { textParts.append(content) }
                if let content = message["content"] as? [[String: Any]] {
                    textParts += content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                }
            }
            let referenceText = textParts.joined(separator: "\n")
            let regex = try NSRegularExpression(pattern: #"\[Image: source: ([^\]]+)\]"#)
            for match in regex.matches(in: referenceText, range: NSRange(referenceText.startIndex..., in: referenceText)) {
                guard let range = Range(match.range(at: 1), in: referenceText) else { continue }
                let original = String(referenceText[range])
                let attachment = attachmentName(for: original)
                let path: URL
                if conversation.imported {
                    path = conversation.sourceURL.deletingLastPathComponent().deletingLastPathComponent()
                        .appendingPathComponent("attachments").appendingPathComponent(attachment)
                } else { path = URL(fileURLWithPath: original) }
                let values = try? path.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard values?.isRegularFile == true, (values?.fileSize ?? Int.max) <= 32 * 1024 * 1024,
                      let data = try? Data(contentsOf: path) else { missing.insert(original); continue }
                files["attachments/" + attachment] = data
                included.insert(original)
            }
        }
        let manifest = ArchiveManifest(format: "claude-conversations", version: 1, createdAt: Date(), conversations: entries)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        files["manifest.json"] = try encoder.encode(manifest)
        files["README.txt"] = Data("Claudy Archive archive v1\nImport this ZIP using Claudy Archive, or unzip it to inspect the original sessions/*.jsonl files.\nOriginal logs may contain private text, paths, credentials and tool results.\nAvailable external image references are in attachments/, keyed by SHA-256 of the original path.\n".utf8)
        let archive = try ZipArchive.encode(files)
        try archive.write(to: destination, options: .atomic)
        return ExportReport(conversations: entries.count, attachments: included.count, missingAttachments: missing.count)
    }

    private static func decodeManifest(_ data: Data) throws -> ArchiveManifest {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(ArchiveManifest.self, from: data)
        guard manifest.format == "claude-conversations", manifest.version == 1 else {
            throw ConversationError.invalid("This archive uses an unsupported format or version.")
        }
        guard !manifest.conversations.isEmpty else { throw ConversationError.invalid("This archive contains no conversations.") }
        var seen = Set<String>()
        for entry in manifest.conversations {
            try ZipArchive.validatePath(entry.file)
            guard entry.file.hasPrefix("sessions/"), entry.file.hasSuffix(".jsonl"),
                  entry.file.split(separator: "/").count == 2, seen.insert(entry.file).inserted else {
                throw ConversationError.invalid("Invalid session path in archive manifest.")
            }
        }
        return manifest
    }

    public static func readManifest(at folder: URL) throws -> ArchiveManifest {
        try decodeManifest(Data(contentsOf: folder.appendingPathComponent("manifest.json")))
    }

    /// Import by validating everything first, then moving a staging directory into the library.
    /// Original Claude Code folders are never written to.
    public static func importArchive(_ archive: URL, library: URL) throws -> Int {
        let values = try archive.resourceValues(forKeys: [.fileSizeKey])
        guard (values.fileSize ?? Int.max) <= ZipArchive.maxArchiveBytes else { throw ConversationError.invalid("Archive is larger than 512 MB.") }
        let files = try ZipArchive.decode(Data(contentsOf: archive))
        guard let bytes = files["manifest.json"] else {
            throw ConversationError.invalid("This ZIP is not a Claudy Archive archive (manifest.json is missing).")
        }
        let manifest = try decodeManifest(bytes)
        for entry in manifest.conversations {
            guard let data = files[entry.file], String(data: data, encoding: .utf8) != nil else {
                throw ConversationError.invalid("Missing or unreadable session: \(entry.file)")
            }
        }
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let fm = FileManager.default, imports = library.appendingPathComponent("Imports")
        let destination = imports.appendingPathComponent(digest)
        if fm.fileExists(atPath: destination.path) { return 0 }
        try fm.createDirectory(at: imports, withIntermediateDirectories: true)
        let stage = library.appendingPathComponent(".import-" + UUID().uuidString)
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stage) }
        // Only extract the expected flat session and attachment paths.
        for (name, data) in files {
            let attachmentParts = name.split(separator: "/")
            let isAttachment = attachmentParts.count == 2 && attachmentParts[0] == "attachments"
            guard name == "manifest.json" || manifest.conversations.contains(where: { $0.file == name }) || isAttachment else { continue }
            let url = stage.appendingPathComponent(name)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        }
        // Ensure a broken log cannot make a successful but unusable import.
        for entry in manifest.conversations {
            let conversation = try HistoryReader.parse(url: stage.appendingPathComponent(entry.file))
            guard !conversation.messages.isEmpty else { throw ConversationError.invalid("Session \(entry.title) has no readable messages.") }
        }
        try fm.moveItem(at: stage, to: destination)
        return manifest.conversations.count
    }
}
