import SwiftUI
import AppKit
import ConversationCore

@main
struct ClaudyArchiveApp: App {
    @StateObject private var model = AppModel()

    init() {
        // The same executable offers a dependency-free smoke check for packaging and real logs.
        if CommandLine.arguments.contains("--diagnose") {
            let root = HistoryReader.defaultProjectsURL
            let result = HistoryReader.scan(projects: root, library: URL(fileURLWithPath: "/nonexistent-claude-library"))
            print("Projects folder: \(root.path)")
            print("Conversations: \(result.conversations.count)")
            print("Projects: \(Set(result.conversations.map(\.projectPath)).count)")
            print("Messages: \(result.conversations.reduce(0) { $0 + $1.messageCount })")
            print("Warnings: \(result.warnings.count)")
            print("Malformed lines skipped: \(result.conversations.reduce(0) { $0 + $1.malformedLines })")
            exit(result.conversations.isEmpty ? 1 : 0)
        }
    }

    var body: some Scene {
        WindowGroup("Claudy Archive") {
            ContentView().environmentObject(model)
                .frame(minWidth: 960, minHeight: 620)
                .task { await model.initialLoad() }
                .onOpenURL { model.importURL($0) }
        }
        .defaultSize(width: 1280, height: 820)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Import Archive…") { model.importArchive() }.keyboardShortcut("o")
                Button("Export Archive…") { model.showExport = true }.keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(model.conversations.isEmpty || model.busy)
            }
            CommandGroup(after: .sidebar) {
                Button("Refresh Conversations") { Task { await model.refresh() } }.keyboardShortcut("r")
                Button("Choose History Folder…") { model.chooseFolder() }
            }
        }
    }
}
