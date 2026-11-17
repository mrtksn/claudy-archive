import XCTest
@testable import ConversationCore

final class ConversationCoreTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("claude-reader-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func log(_ records: [[String: Any]], name: String = "session") throws -> URL {
        let url = root.appendingPathComponent(name + ".jsonl")
        let lines = try records.map { String(data: try JSONSerialization.data(withJSONObject: $0, options: .sortedKeys), encoding: .utf8)! }
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
        return url
    }
    private func user(_ text: String, id: String = "user") -> [String: Any] {
        ["type": "user", "uuid": id, "cwd": "/Users/test/projects/airframe", "timestamp": "2026-11-17T10:00:00.000Z", "message": ["content": text]]
    }

    func testPartialLogDuplicateAndToolGrouping() throws {
        let url = try log([
            user("Actual question"), user("Actual question"),
            ["type": "assistant", "uuid": "a", "message": ["content": [["type": "text", "text": "First part"], ["type": "thinking", "thinking": "Hidden"]]]],
            ["type": "assistant", "uuid": "b", "message": ["content": [["type": "tool_use", "name": "Read", "input": ["path": "/test"]]]]],
            ["type": "user", "uuid": "c", "message": ["content": [["type": "tool_result", "content": "The result"]]]],
            ["type": "assistant", "uuid": "d", "message": ["content": [["type": "text", "text": "Conclusion"]]]],
            ["type": "custom-title", "customTitle": "A custom title"],
            user("<local-command-stdout>noise</local-command-stdout>", id: "noise")
        ])
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd(); try handle.write(contentsOf: Data("{incomplete".utf8)); try handle.close()
        let conversation = try HistoryReader.parse(url: url)
        XCTAssertEqual(conversation.title, "A custom title")
        XCTAssertEqual(conversation.project, "airframe")
        XCTAssertEqual(conversation.messages.count, 2)
        XCTAssertEqual(conversation.messages[1].text, "First part\n\nConclusion")
        XCTAssertEqual(conversation.messages[1].tools.count, 2)
        XCTAssertEqual(conversation.malformedLines, 1)
        XCTAssertFalse(conversation.searchText.contains("Hidden"))
    }

    func testStoredAndDeflatedZIPRoundTrip() throws {
        let files = ["empty.txt": Data(), "sessions/a.jsonl": Data(repeating: 65, count: 80_000), "Unicode/日本語.txt": Data("hello 🌍".utf8)]
        let zip = try ZipArchive.encode(files)
        XCTAssertLessThan(zip.count, 2000)
        XCTAssertEqual(try ZipArchive.decode(zip), files)
    }

    func testImageReferenceCompanionDoesNotRepeatEmbeddedPromptImage() throws {
        var prompt = user("Question")
        prompt["message"] = ["content": [["type": "text", "text": "Question"],
            ["type": "image", "source": ["type": "base64", "data": "aGVsbG8=", "media_type": "image/png"]]]]
        let reference = user("[Image: source: /tmp/photo.png]", id: "reference")
        let chat = try HistoryReader.parse(url: log([prompt, reference]))
        XCTAssertEqual(chat.messages.count, 1)
        XCTAssertEqual(chat.messages[0].images.count, 1)
        XCTAssertEqual(chat.messages[0].text, "Question")
    }

    func testPythonStandardZIPCompatibility() throws {
        let zip = Data(base64Encoded: "UEsDBBQAAAAIAISVcV3IvQa9GgAAAHwBAAAJAAAAaGVsbG8udHh0y0jNyclXKC5JzEtJLEpRiPIM4MoYFaKPEABQSwECFAMUAAAACACElXFdyL0GvRoAAAB8AQAACQAAAAAAAAAAAAAAgAEAAAAAaGVsbG8udHh0UEsFBgAAAAABAAEANwAAAEEAAAAAAA==")!
        let files = try ZipArchive.decode(zip)
        XCTAssertEqual(files["hello.txt"], Data(String(repeating: "hello standard ZIP\n", count: 20).utf8))
    }

    func testZIPRejectsTraversalAndCorruption() throws {
        for path in ["../outside", "/absolute", "a/../outside", "a\\outside", "./file", "a//b", "C:file"] {
            XCTAssertThrowsError(try ZipArchive.encode([path: Data()]), path)
        }
        var zip = try ZipArchive.encode(["a": Data([0, 1, 2, 3, 4])])
        zip[31] ^= 0xff // Stored entry payload, CRC must fail.
        XCTAssertThrowsError(try ZipArchive.decode(zip))
        XCTAssertThrowsError(try ZipArchive.decode(Data(zip.prefix(20))))
    }

    func testZIPRejectsSymlinks() throws {
        var zip = try ZipArchive.encode(["link": Data("target".utf8)])
        let marker = Data([0x50, 0x4b, 0x01, 0x02])
        let central = try XCTUnwrap(zip.range(of: marker)).lowerBound
        zip[central + 40] = 0xff
        zip[central + 41] = 0xa1 // Unix file mode = symlink.
        XCTAssertThrowsError(try ZipArchive.decode(zip))
    }

    func testArchiveRoundTripPreservesRawLogsAndExternalImages() throws {
        let image = root.appendingPathComponent("picture.png")
        let imageData = Data([137, 80, 78, 71])
        try imageData.write(to: image)
        let source = try log([user("Look at this [Image: source: \(image.path)]"),
            ["type": "assistant", "uuid": "a", "message": ["content": [["type": "text", "text": "A reply"]]]]])
        let before = try Data(contentsOf: source)
        let chat = try HistoryReader.parse(url: source)
        let zip = root.appendingPathComponent("export.zip")
        let report = try ArchiveService.export([chat], to: zip)
        XCTAssertEqual(report.attachments, 1)
        let library = root.appendingPathComponent("Library")
        XCTAssertEqual(try ArchiveService.importArchive(zip, library: library), 1)
        XCTAssertEqual(try ArchiveService.importArchive(zip, library: library), 0)
        let scan = HistoryReader.scan(projects: root.appendingPathComponent("no-projects"), library: library)
        let imported = try XCTUnwrap(scan.conversations.first)
        XCTAssertTrue(imported.imported)
        XCTAssertEqual(imported.projectPath, chat.projectPath)
        XCTAssertEqual(imported.title, chat.title)
        XCTAssertEqual(try Data(contentsOf: imported.sourceURL), before)
        let importedImage = try XCTUnwrap(imported.messages.first?.images.first)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: importedImage.path)), imageData)
        let secondZip = root.appendingPathComponent("re-export.zip")
        XCTAssertEqual(try ArchiveService.export([imported], to: secondZip).attachments, 1)
        XCTAssertEqual(try Data(contentsOf: source), before, "Original history must remain unchanged")
    }

    func testImportIsAtomicWhenSessionIsUnreadable() throws {
        let manifest = ArchiveManifest(format: "claude-conversations", version: 1, createdAt: Date(), conversations: [ArchiveEntry(file: "sessions/empty.jsonl", title: "Empty", projectPath: "/test", modified: Date())])
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let zip = try ZipArchive.encode(["manifest.json": try encoder.encode(manifest), "sessions/empty.jsonl": Data("garbage".utf8)])
        let url = root.appendingPathComponent("bad.zip"); try zip.write(to: url)
        let library = root.appendingPathComponent("Library")
        XCTAssertThrowsError(try ArchiveService.importArchive(url, library: library))
        let imports = try FileManager.default.contentsOfDirectory(atPath: library.appendingPathComponent("Imports").path)
        XCTAssertTrue(imports.isEmpty)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: library.path).contains { $0.hasPrefix(".import-") })
    }

    func testUnavailableExternalImageReportedAndEmbeddedImageRetained() throws {
        let url = try log([user("[Image: source: /nonexistent/image.png]"),
            ["type": "user", "uuid": "embedded", "message": ["content": [["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": "aGVsbG8="]]]]]])
        let chat = try HistoryReader.parse(url: url)
        XCTAssertEqual(chat.messages.last?.images.first?.data, Data("hello".utf8))
        let report = try ArchiveService.export([chat], to: root.appendingPathComponent("out.zip"))
        XCTAssertEqual(report.missingAttachments, 1)
        XCTAssertEqual(report.attachments, 0)
    }
}
