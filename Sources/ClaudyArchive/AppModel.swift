import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ConversationCore

@MainActor
final class AppModel: ObservableObject {
    @Published var conversations: [Conversation] = []
    @Published var selection: String?
    @Published var project: String?
    @Published var origin = "All"
    @Published var query = ""
    @Published var busy = false
    @Published var activity = ""
    @Published var notice: String?
    @Published var error: String?
    @Published var warnings: [String] = []
    @Published var showExport = false
    @Published var showInfo = false
    @Published var showTools = false
    @Published var projectsURL: URL

    let libraryURL: URL
    private var loaded = false

    init() {
        let defaults = UserDefaults.standard
        projectsURL = defaults.string(forKey: "projectsPath").map { URL(fileURLWithPath: $0) }
            ?? HistoryReader.defaultProjectsURL
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let current = support.appendingPathComponent("Claudy Archive")
        let legacy = support.appendingPathComponent("Claude Conversations")
        let environment = ProcessInfo.processInfo.environment
        let override = environment["CLAUDY_ARCHIVE_LIBRARY"] ?? environment["CLAUDE_CONVERSATIONS_LIBRARY"]
        libraryURL = override.map { URL(fileURLWithPath: $0) }
            ?? (!FileManager.default.fileExists(atPath: current.path)
                && FileManager.default.fileExists(atPath: legacy.path) ? legacy : current)
    }

    var projects: [String] { Array(Set(conversations.map(\.projectPath))).sorted { $0.localizedStandardCompare($1) == .orderedAscending } }
    var filtered: [Conversation] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return conversations.filter {
            (project == nil || $0.projectPath == project) &&
            (origin == "All" || (origin == "Imported" ? $0.imported : !$0.imported)) &&
            (needle.isEmpty || $0.searchText.contains(needle))
        }
    }
    var selected: Conversation? { conversations.first { $0.id == selection } }

    func initialLoad() async {
        guard !loaded else { return }
        loaded = true
        await refresh()
    }

    func refresh() async {
        guard !busy else { return }
        busy = true; activity = "Reading local conversations…"
        let projects = projectsURL, library = libraryURL
        let scan = await Task.detached(priority: .userInitiated) { HistoryReader.scan(projects: projects, library: library) }.value
        conversations = scan.conversations; warnings = scan.warnings
        if let selection, !conversations.contains(where: { $0.id == selection }) { self.selection = nil }
        if selection == nil { selection = filtered.first?.id }
        busy = false
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose Claude Code history folder"
        panel.message = "Choose the projects folder inside .claude. Hidden folders are visible."
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.showsHiddenFiles = true
        panel.directoryURL = projectsURL
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            self.projectsURL = url
            UserDefaults.standard.set(url.path, forKey: "projectsPath")
            Task { await self.refresh() }
        }
    }

    func importArchive() {
        guard !busy else { return }
        let panel = NSOpenPanel()
        panel.title = "Import conversation archive"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.zip]
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            self.importURL(url)
        }
    }

    func importURL(_ url: URL) {
        guard !busy else { return }
        busy = true; activity = "Importing archive…"
        let library = libraryURL
        Task {
            do {
                let count = try await Task.detached(priority: .userInitiated) { try ArchiveService.importArchive(url, library: library) }.value
                busy = false
                project = nil; origin = "Imported"; query = ""; selection = nil
                await refresh()
                notice = count == 0 ? "This archive is already in your library." : "Imported \(count) conversation\(count == 1 ? "" : "s")."
            } catch { busy = false; self.error = error.localizedDescription }
        }
    }

    func export(_ items: [Conversation]) {
        guard !busy, !items.isEmpty else { return }
        showExport = false
        let panel = NSSavePanel()
        panel.title = "Export conversation archive"
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = "Claudy Archive \(Date().formatted(.iso8601.year().month().day().dateSeparator(.dash))).zip"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            self.performExport(items, to: url)
        }
    }

    private func performExport(_ items: [Conversation], to url: URL) {
        busy = true; activity = "Creating archive…"
        Task {
            do {
                let report = try await Task.detached(priority: .userInitiated) { try ArchiveService.export(items, to: url) }.value
                busy = false
                var message = "Exported \(report.conversations) conversation\(report.conversations == 1 ? "" : "s") and \(report.attachments) linked image\(report.attachments == 1 ? "" : "s")."
                if report.missingAttachments > 0 { message += " \(report.missingAttachments) old image file\(report.missingAttachments == 1 ? " was" : "s were") unavailable; their references and any embedded images remain in the logs." }
                notice = message
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch { busy = false; self.error = error.localizedDescription }
        }
    }
}
