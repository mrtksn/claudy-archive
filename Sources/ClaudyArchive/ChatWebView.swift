import SwiftUI
import WebKit
import ImageIO
import UniformTypeIdentifiers
import ConversationCore

struct ChatWebView: NSViewRepresentable {
    let conversation: Conversation
    let showTools: Bool
    let query: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.setValue(false, forKey: "drawsBackground")
        view.navigationDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = false
        view.setAccessibilityLabel("Conversation messages")
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        let key = "\(conversation.id)|\(conversation.modified.timeIntervalSince1970)|\(showTools)|\(query)"
        guard context.coordinator.key != key else { return }
        context.coordinator.key = key
        let records = conversation.messages.compactMap { message -> [String: Any]? in
            if message.text.isEmpty && message.images.isEmpty && (!showTools || message.tools.isEmpty) { return nil }
            var images: [[String: String]] = []
            for image in message.images {
                if let preview = thumbnail(image) { images.append(["url": "data:image/jpeg;base64," + preview.base64EncodedString()]) }
                else { images.append(["missing": "Image unavailable" + (image.path.isEmpty ? "" : " · " + URL(fileURLWithPath: image.path).lastPathComponent)]) }
            }
            return ["id": message.id, "role": message.role, "text": message.text, "timestamp": message.timestamp,
                    "tools": showTools ? message.tools.map { ["name": $0.name, "text": String($0.text.prefix(30_000)), "truncated": $0.text.count > 30_000] } : [],
                    "images": images]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: ["messages": records, "query": query]),
              let resource = Bundle.module.url(forResource: "chat", withExtension: "html", subdirectory: "Resources"),
              let template = try? String(contentsOf: resource, encoding: .utf8) else { return }
        // Base64 keeps conversation text out of the HTML/JS syntax entirely.
        let html = template.replacingOccurrences(of: "__PAYLOAD__", with: data.base64EncodedString())
        view.loadHTMLString(html, baseURL: nil)
    }

    private func thumbnail(_ image: ChatImage) -> Data? {
        let source: CGImageSource?
        if let data = image.data { source = CGImageSourceCreateWithData(data as CFData, nil) }
        else {
            let url = URL(fileURLWithPath: image.path)
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 32 * 1024 * 1024 else { return nil }
            source = CGImageSourceCreateWithURL(url as CFURL, nil)
        }
        guard let source, let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 1200,
            kCGImageSourceCreateThumbnailWithTransform: true
        ] as CFDictionary) else { return nil }
        let result = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(result, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, cgImage, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return result as Data
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var key = ""
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
                if ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") { NSWorkspace.shared.open(url) }
                decisionHandler(.cancel)
            } else if navigationAction.request.url?.scheme == "about" {
                decisionHandler(.allow)
            } else { decisionHandler(.cancel) }
        }
    }
}
