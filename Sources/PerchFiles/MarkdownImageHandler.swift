import UniformTypeIdentifiers
import WebKit

@MainActor
final class MarkdownImageHandler: NSObject, WKURLSchemeHandler {
    private let documentURL: URL
    private var pending: [ObjectIdentifier: Task<Void, Never>] = [:]

    init(documentURL: URL) {
        self.documentURL = documentURL
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let requestURL = urlSchemeTask.request.url,
              requestURL.host == "local",
              let reference = URLComponents(url: requestURL, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "path" })?.value,
              !reference.isEmpty else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }

        let id = ObjectIdentifier(urlSchemeTask)
        let documentURL = self.documentURL
        pending[id] = Task {
            let result = await Task.detached(priority: .utility) {
                try Self.loadImage(reference, relativeTo: documentURL)
            }.result
            guard !Task.isCancelled else { return }
            pending[id] = nil
            switch result {
            case .success(let image):
                urlSchemeTask.didReceive(URLResponse(
                    url: requestURL, mimeType: image.mimeType,
                    expectedContentLength: image.data.count, textEncodingName: nil
                ))
                urlSchemeTask.didReceive(image.data)
                urlSchemeTask.didFinish()
            case .failure(let error):
                urlSchemeTask.didFailWithError(error)
            }
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        pending.removeValue(forKey: ObjectIdentifier(urlSchemeTask))?.cancel()
    }

    private nonisolated static func loadImage(_ reference: String, relativeTo documentURL: URL) throws
        -> (data: Data, mimeType: String) {
        let folder = documentURL.resolvingSymlinksInPath().deletingLastPathComponent()
        guard let url = URL(string: reference, relativeTo: folder)?.absoluteURL, url.isFileURL else {
            throw URLError(.badURL)
        }
        let file = url.resolvingSymlinksInPath()
        let resource = try file.resourceValues(forKeys: [.isRegularFileKey, .contentTypeKey])
        guard resource.isRegularFile == true,
              let type = resource.contentType, type.conforms(to: .image),
              let mimeType = type.preferredMIMEType else {
            throw URLError(.cannotDecodeContentData)
        }
        return (try Data(contentsOf: file, options: .mappedIfSafe), mimeType)
    }
}
