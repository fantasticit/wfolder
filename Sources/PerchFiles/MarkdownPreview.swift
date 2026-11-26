import SwiftUI
import WebKit

struct MarkdownPreview: View {
    let entry: FileEntry
    let source: String
    @Environment(\.colorScheme) private var colorScheme
    @ViewState private var showingSource = false
    @ViewState private var renderingFailed = false

    var body: some View {
        VStack(spacing: 0) {
            if !renderingFailed {
                Picker("Markdown 预览模式", selection: $showingSource) {
                    Text("渲染").tag(false)
                    Text("源码").tag(true)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                Divider()
            }
            if showingSource || renderingFailed {
                TextPreview(entry: entry, text: source, monospaced: true, highlights: [])
            } else {
                MarkdownWebView(source: source, documentURL: entry.url) { renderingFailed = true }
                    .id(colorScheme)
            }
        }
        .accessibilityLabel("Markdown 预览")
    }
}

private struct MarkdownWebView: NSViewRepresentable {
    let source: String
    let documentURL: URL
    let onFailure: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(source: source, onFailure: onFailure) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.setURLSchemeHandler(MarkdownImageHandler(documentURL: documentURL), forURLScheme: "wfolder-image")
        let view = WKWebView(frame: .zero, configuration: config)
        view.underPageBackgroundColor = .clear
        view.setAccessibilityLabel("Markdown 正文")
        view.navigationDelegate = context.coordinator

        let needsDiagrams = source.range(of: "mermaid", options: .caseInsensitive) != nil
        guard let page = Assets.page, let renderer = Assets.renderer else {
            DispatchQueue.main.async(execute: onFailure)
            return view
        }
        config.userContentController.addUserScript(Self.script(renderer))
        if needsDiagrams, let diagrams = Assets.diagrams {
            config.userContentController.addUserScript(Self.script(diagrams))
        }
        view.loadHTMLString(page, baseURL: nil)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {}

    private static func script(_ source: String) -> WKUserScript {
        WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let source: String
        let onFailure: () -> Void

        init(source: String, onFailure: @escaping () -> Void) {
            self.source = source
            self.onFailure = onFailure
        }

        func webView(_ view: WKWebView, didFinish navigation: WKNavigation!) {
            view.callAsyncJavaScript(
                "globalThis.showMarkdown(source)",
                arguments: ["source": source],
                in: nil,
                in: .page
            ) { [weak self] result in
                if case .failure = result { self?.onFailure() }
            }
        }

        func webView(_ view: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { onFailure() }
        func webView(_ view: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            onFailure()
        }
        func webViewWebContentProcessDidTerminate(_ view: WKWebView) { onFailure() }

        func webView(_ view: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url else { return decisionHandler(.cancel) }
            if action.targetFrame?.isMainFrame == true, url.scheme == "about",
               url.absoluteString == "about:blank" || url.absoluteString.hasPrefix("about:blank#") {
                return decisionHandler(.allow)
            }
            if action.navigationType == .linkActivated, ["https", "http", "mailto"].contains(url.scheme ?? "") {
                NSWorkspace.shared.open(url)
            }
            decisionHandler(.cancel)
        }
    }

    private enum Assets {
        static let page = read("preview", ext: "html")
        static let renderer = read("preview", ext: "js")
        static let diagrams = read("diagrams", ext: "js")

        private static func read(_ name: String, ext: String) -> String? {
            #if SWIFT_PACKAGE
            let bundle = Bundle.module
            #else
            let bundle = Bundle.main
            #endif
            guard let url = bundle.url(forResource: name, withExtension: ext, subdirectory: "Markdown") else {
                return nil
            }
            return try? String(contentsOf: url, encoding: .utf8)
        }
    }
}
