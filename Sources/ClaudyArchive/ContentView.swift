import SwiftUI
import AppKit
import ConversationCore

private let canvas = Color(nsColor: NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? NSColor(srgbRed: 0.14, green: 0.14, blue: 0.13, alpha: 1)
        : NSColor(srgbRed: 0.98, green: 0.97, blue: 0.95, alpha: 1)
})
private let clay = Color(red: 0.76, green: 0.36, blue: 0.24)

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        NavigationSplitView {
            sidebar.navigationSplitViewColumnWidth(min: 195, ideal: 220, max: 320)
        } content: {
            conversationList.navigationSplitViewColumnWidth(min: 235, ideal: 290, max: 390)
        } detail: {
            chat
        }
        .tint(clay)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if model.busy { ProgressView().controlSize(.small).help(model.activity) }
                Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh (⌘R)").disabled(model.busy)
                Button { model.importArchive() } label: { Label("Import", systemImage: "square.and.arrow.down") }.disabled(model.busy)
                Button { model.showExport = true } label: { Label("Export", systemImage: "square.and.arrow.up") }
                    .disabled(model.conversations.isEmpty || model.busy)
            }
        }
        .sheet(isPresented: $model.showExport) { ExportSheet().environmentObject(model) }
        .sheet(isPresented: $model.showInfo) { LibraryInfo().environmentObject(model) }
        .alert("Couldn’t complete the operation", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
        .alert("Archive ready", isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })) {
            Button("OK") { model.notice = nil }
        } message: { Text(model.notice ?? "") }
        .background(canvas)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "text.bubble.fill").font(.system(size: 26)).foregroundStyle(clay)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Conversations").font(.system(.headline, design: .serif))
                    Text("Your Claude Code library").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(.horizontal, 16).padding(.top, 20).padding(.bottom, 22)
            List(selection: $model.project) {
                Label("All conversations", systemImage: "bubble.left.and.bubble.right")
                    .badge(model.conversations.count).tag(Optional<String>.none)
                Section("Projects") {
                    ForEach(model.projects, id: \.self) { path in
                        HStack {
                            Image(systemName: "folder").foregroundStyle(.secondary)
                            Text(URL(fileURLWithPath: path).lastPathComponent).lineLimit(1)
                            Spacer(minLength: 2)
                            Text("\(model.conversations.filter { $0.projectPath == path }.count)")
                                .font(.caption).foregroundStyle(.tertiary)
                        }.help(path).tag(Optional(path))
                    }
                }
            }.listStyle(.sidebar)
            Divider()
            VStack(alignment: .leading, spacing: 11) {
                Button { model.chooseFolder() } label: { Label("Choose history folder…", systemImage: "folder.badge.gearshape") }
                Button { model.showInfo = true } label: { Label("Library details", systemImage: "info.circle") }
                Text("On your Mac · No sign-in needed").font(.caption2).foregroundStyle(.tertiary)
            }.buttonStyle(.plain).font(.caption).foregroundStyle(.secondary).padding(16)
        }
        .onChange(of: model.project) { _, _ in model.selection = model.filtered.first?.id }
    }

    private var conversationList: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(model.project.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "All conversations")
                        .font(.headline).lineLimit(1)
                    Spacer()
                    Text("\(model.filtered.count)").foregroundStyle(.secondary).font(.caption)
                }
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search titles and messages", text: $model.query).textFieldStyle(.plain).focused($searchFocused)
                    if !model.query.isEmpty {
                        Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }.buttonStyle(.plain)
                    }
                }.padding(8).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                Picker("Source", selection: $model.origin) {
                    ForEach(["All", "Local", "Imported"], id: \.self) { Text($0).tag($0) }
                }.pickerStyle(.segmented).labelsHidden()
            }.padding(14)
            Divider()
            if model.filtered.isEmpty {
                ContentUnavailableView(model.busy ? "Reading conversations" : "No conversations", systemImage: model.busy ? "clock" : "bubble.left",
                    description: Text(model.query.isEmpty ? "Choose a history folder or import an archive." : "Try another search or source filter."))
            } else {
                List(selection: $model.selection) {
                    ForEach(model.filtered) { conversation in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(conversation.title).font(.system(size: 13, weight: .medium)).lineLimit(2)
                            HStack(spacing: 5) {
                                if conversation.imported { Image(systemName: "archivebox").font(.caption2) }
                                Text(conversation.modified, format: .dateTime.month(.abbreviated).day())
                                Text("·")
                                Text("\(conversation.messageCount) messages")
                            }.font(.caption).foregroundStyle(.secondary)
                            if model.project == nil { Text(conversation.project).font(.caption2).foregroundStyle(.tertiary).lineLimit(1) }
                        }.padding(.vertical, 7).tag(conversation.id)
                            .contextMenu {
                                Button("Export This Conversation…") { model.export([conversation]) }
                                Button("Show Original File") { NSWorkspace.shared.activateFileViewerSelecting([conversation.sourceURL]) }
                                Button("Copy Title") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(conversation.title, forType: .string) }
                            }
                    }
                }.listStyle(.inset)
            }
            Divider()
            HStack {
                Circle().fill(model.busy ? Color.orange : Color.green).frame(width: 5, height: 5)
                Text(model.busy ? model.activity : "\(model.conversations.count) conversations in your library")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
            }.padding(10)
        }.background(canvas)
            .background(Button("Find") { searchFocused = true }.keyboardShortcut("f").hidden())
            .onChange(of: model.origin) { _, _ in model.selection = model.filtered.first?.id }
            .onChange(of: model.query) { _, _ in
                if !model.filtered.contains(where: { $0.id == model.selection }) { model.selection = model.filtered.first?.id }
            }
    }

    @ViewBuilder private var chat: some View {
        if let conversation = model.selected {
            VStack(spacing: 0) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(conversation.title).font(.system(size: 19, weight: .medium, design: .serif)).lineLimit(2).textSelection(.enabled)
                        HStack(spacing: 6) {
                            Text(conversation.project)
                            Text("·")
                            Text(conversation.modified, format: .dateTime.month().day().year())
                            if conversation.imported { Text("· Imported") }
                        }.font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 10)
                    Toggle(isOn: $model.showTools) { Image(systemName: "terminal") }.toggleStyle(.button)
                        .help("Show tool calls and results")
                    Menu {
                        Button("Export This Conversation…") { model.export([conversation]) }
                        Button("Copy Conversation") {
                            let text = conversation.messages.filter { !$0.text.isEmpty }.map { "\($0.role == "user" ? "You" : "Claude"):\n\($0.text)" }.joined(separator: "\n\n")
                            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
                        }
                        Button("Show Original File") { NSWorkspace.shared.activateFileViewerSelecting([conversation.sourceURL]) }
                    } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).frame(width: 25)
                }.padding(.horizontal, 28).padding(.vertical, 20)
                Divider()
                ChatWebView(conversation: conversation, showTools: model.showTools, query: model.query)
                Divider()
                HStack(spacing: 6) {
                    Image(systemName: "archivebox")
                    Text("Conversation history").fontWeight(.medium)
                    Text("· Original files stay unchanged")
                    Spacer()
                    if conversation.malformedLines > 0 { Text("\(conversation.malformedLines) incomplete lines skipped").help("Claude may still be writing the last JSONL record. Refresh to read new content.") }
                }.font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 24).padding(.vertical, 11)
            }.background(canvas)
        } else {
            VStack(spacing: 17) {
                Image(systemName: "text.bubble").font(.system(size: 45, weight: .light)).foregroundStyle(clay)
                Text("A place for your conversations").font(.system(size: 28, design: .serif))
                Text("Browse your Claude Code history, find an idea,\nand keep an archive you can come back to.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
                Button("Import an archive…") { model.importArchive() }.buttonStyle(.bordered)
            }.frame(maxWidth: .infinity, maxHeight: .infinity).background(canvas)
        }
    }
}

struct ExportSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var scope = "selected"
    private var items: [Conversation] {
        switch scope {
        case "visible": return model.filtered
        case "all": return model.conversations
        default: return model.selected.map { [$0] } ?? []
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("Export conversations", systemImage: "archivebox").font(.title2)
            Text("A ZIP you can import on this Mac or another Mac.").foregroundStyle(.secondary)
            Picker("Include", selection: $scope) {
                Text("Selected conversation").tag("selected")
                Text("Current list (\(model.filtered.count))").tag("visible")
                Text("Entire library (\(model.conversations.count))").tag("all")
            }.pickerStyle(.radioGroup)
            Text("Includes original session logs, tool records, embedded images and available linked images. Archives contain private conversation data, including any credentials in the original logs.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Export \(items.count)\(items.count == 1 ? " conversation" : " conversations")…") { model.export(items) }
                    .keyboardShortcut(.defaultAction).disabled(items.isEmpty)
            }
        }.padding(28).frame(width: 480)
            .onAppear { if model.selected == nil { scope = "all" } }
    }
}

struct LibraryInfo: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Your conversation library").font(.title2)
            Text("Claude Code history").font(.headline)
            Text(model.projectsURL.path).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            Text("Imported archives").font(.headline)
            Text(model.libraryURL.appendingPathComponent("Imports").path).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            Text("Everything is read locally. This app doesn’t connect to Claude or send your chats to a server. Imported copies live in this app’s library; the Claude Code history is only read.")
                .font(.callout).foregroundStyle(.secondary)
            if !model.warnings.isEmpty {
                Text("Reader notes").font(.headline)
                ScrollView { Text(model.warnings.joined(separator: "\n\n")).font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 150)
            }
            HStack {
                Button("Open Library Folder") {
                    try? FileManager.default.createDirectory(at: model.libraryURL, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(model.libraryURL)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }.padding(28).frame(width: 540)
    }
}
