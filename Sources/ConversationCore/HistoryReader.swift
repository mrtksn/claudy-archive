import Foundation

public enum HistoryReader {
    public static var defaultProjectsURL: URL {
        let environment = ProcessInfo.processInfo.environment
        let base = environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        return base.appendingPathComponent("projects")
    }

    public static func scan(projects: URL, library: URL) -> ScanResult {
        var result: [Conversation] = []
        var warnings: [String] = []
        let fm = FileManager.default
        if fm.fileExists(atPath: projects.path) {
            do {
                let folders = try fm.contentsOfDirectory(at: projects, includingPropertiesForKeys: [.isDirectoryKey])
                for folder in folders where (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    do {
                        let files = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])
                        for file in files where file.pathExtension == "jsonl" {
                            do { result.append(try parse(url: file)) }
                            catch { warnings.append("\(file.lastPathComponent): \(error.localizedDescription)") }
                        }
                    } catch { warnings.append("\(folder.lastPathComponent): \(error.localizedDescription)") }
                }
            } catch { warnings.append(error.localizedDescription) }
        } else { warnings.append("No Claude Code projects folder at \(projects.path). Use Choose history folder to select another location.") }

        let imports = library.appendingPathComponent("Imports")
        if let folders = try? fm.contentsOfDirectory(at: imports, includingPropertiesForKeys: nil) {
            for folder in folders {
                do {
                    let manifest = try ArchiveService.readManifest(at: folder)
                    for entry in manifest.conversations {
                        let url = folder.appendingPathComponent(entry.file)
                        var conversation = try parse(url: url, imported: true,
                            projectOverride: entry.projectPath, titleOverride: entry.title,
                            attachmentRoot: folder.appendingPathComponent("attachments"))
                        conversation.modified = entry.modified
                        result.append(conversation)
                    }
                } catch { warnings.append("Imported archive \(folder.lastPathComponent): \(error.localizedDescription)") }
            }
        }
        result.sort { $0.modified > $1.modified }
        return ScanResult(conversations: result, warnings: warnings)
    }

    public static func parse(url: URL, imported: Bool = false, projectOverride: String? = nil,
                             titleOverride: String? = nil, attachmentRoot: URL? = nil) throws -> Conversation {
        let data = try Data(contentsOf: url)
        guard data.count <= 256 * 1024 * 1024 else { throw ConversationError.invalid("Session exceeds the 256 MB reader limit.") }
        guard let text = String(data: data, encoding: .utf8) else { throw ConversationError.invalid("Session is not UTF-8 JSONL.") }
        var messages: [ChatMessage] = []
        var seen = Set<String>()
        var title = ""
        var projectPath = projectOverride ?? ""
        var firstUser = ""
        var malformed = 0
        var latestTimestamp = ""
        let sessionID = url.deletingPathExtension().lastPathComponent

        for (index, line) in text.split(separator: "\n").enumerated() {
            guard let bytes = line.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any] else {
                malformed += 1; continue
            }
            if projectPath.isEmpty, let cwd = obj["cwd"] as? String { projectPath = cwd }
            if let value = obj["timestamp"] as? String, value > latestTimestamp { latestTimestamp = value }
            if obj["type"] as? String == "custom-title" {
                title = obj["customTitle"] as? String ?? obj["title"] as? String ?? title
            }
            guard let role = obj["type"] as? String, role == "user" || role == "assistant",
                  obj["isSidechain"] as? Bool != true,
                  let message = obj["message"] as? [String: Any] else { continue }
            let uuid = obj["uuid"] as? String ?? "line-\(index)"
            guard seen.insert(uuid).inserted else { continue }
            var parts: [String] = []
            var tools: [ToolRecord] = []
            var images: [ChatImage] = []
            if let content = message["content"] as? String { parts.append(content) }
            if let blocks = message["content"] as? [[String: Any]] {
                for block in blocks {
                    switch block["type"] as? String {
                    case "text": parts.append(block["text"] as? String ?? "")
                    case "tool_use":
                        let input = block["input"].flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]) }
                        tools.append(ToolRecord(name: block["name"] as? String ?? "Tool", text: input.flatMap { String(data: $0, encoding: .utf8) } ?? ""))
                    case "tool_result":
                        var value = block["content"] as? String ?? ""
                        if let blocks = block["content"] as? [[String: Any]] {
                            value = blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
                        }
                        tools.append(ToolRecord(name: block["is_error"] as? Bool == true ? "Tool error" : "Tool result", text: value))
                    case "image":
                        if let source = block["source"] as? [String: Any], let encoded = source["data"] as? String {
                            images.append(ChatImage(path: "", mediaType: source["media_type"] as? String ?? "image/png", data: Data(base64Encoded: encoded)))
                        }
                    default: break
                    }
                }
            }
            let body = parts.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
            // These are CLI bookkeeping, not messages typed by the person.
            let internalPrefixes = ["<local-command", "<command-name>", "<command-message>", "<task-notification>",
                                    "[Request interrupted", "[Earlier usage-limit", "[Usage limit reached;"]
            if internalPrefixes.contains(where: { body.hasPrefix($0) }) { continue }
            if body.hasPrefix("This session is being continued") {
                tools.append(ToolRecord(name: "Earlier context summary", text: body))
                parts = []
            }
            var displayText = parts.isEmpty ? "" : body
            let pattern = #"\[Image: source: ([^\]]+)\]"#
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(displayText.startIndex..., in: displayText)
                for match in regex.matches(in: displayText, range: range) {
                    if let range = Range(match.range(at: 1), in: displayText) {
                        let path = String(displayText[range])
                        let resolved: String
                        if let attachmentRoot {
                            let filename = ArchiveService.attachmentName(for: path)
                            resolved = attachmentRoot.appendingPathComponent(filename).path
                        } else { resolved = path }
                        images.append(ChatImage(path: resolved, mediaType: "image/" + URL(fileURLWithPath: path).pathExtension, data: nil))
                    }
                }
                displayText = regex.stringByReplacingMatches(in: displayText, range: range, withTemplate: "").trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if role == "user", firstUser.isEmpty, !displayText.isEmpty { firstUser = displayText }
            if displayText.isEmpty && tools.isEmpty && images.isEmpty { continue }
            let timestamp = obj["timestamp"] as? String ?? ""
            // Claude writes separate records for streamed text/tool blocks in one response.
            if role == "user", displayText.isEmpty, !images.isEmpty,
               let last = messages.last, last.role == "user", last.timestamp == timestamp {
                // A companion image-reference record can repeat an image already embedded
                // in the prompt. Prefer the self-contained copy, while retaining both raw records.
                let repeatsEmbedded = !last.images.isEmpty && last.images.allSatisfy { $0.data != nil }
                    && images.allSatisfy { $0.data == nil } && images.count <= last.images.count
                if !repeatsEmbedded { messages[messages.count - 1].images += images }
                messages[messages.count - 1].tools += tools
            } else if role == "assistant", let last = messages.last, last.role == "assistant" {
                messages[messages.count - 1].text += (last.text.isEmpty || displayText.isEmpty ? "" : "\n\n") + displayText
                messages[messages.count - 1].tools += tools
                messages[messages.count - 1].images += images
            } else if role == "user", displayText.isEmpty, images.isEmpty, !tools.isEmpty,
                      messages.last?.role == "assistant" {
                messages[messages.count - 1].tools += tools
            } else {
                messages.append(ChatMessage(id: uuid, role: role, text: displayText, timestamp: timestamp, tools: tools, images: images))
            }
        }
        if projectPath.isEmpty { projectPath = url.deletingLastPathComponent().lastPathComponent }
        if title.isEmpty { title = String(firstUser.replacingOccurrences(of: "\n", with: " ").prefix(100)) }
        if title.isEmpty { title = "Untitled conversation" }
        if let titleOverride { title = titleOverride }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: latestTimestamp)
            ?? ISO8601DateFormatter().date(from: latestTimestamp)
            ?? (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        let project = URL(fileURLWithPath: projectPath).lastPathComponent
        let search = ([title, projectPath] + messages.map(\.text)).joined(separator: "\n").lowercased()
        return Conversation(sessionID: sessionID, title: title, project: project, projectPath: projectPath,
                            sourceURL: url, modified: date, messages: messages, imported: imported,
                            malformedLines: malformed, searchText: search)
    }
}
