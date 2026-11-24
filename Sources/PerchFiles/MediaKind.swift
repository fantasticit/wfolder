import UniformTypeIdentifiers

enum MediaKind: Sendable {
    case video, audio

    static let transportStreams: Set<String> = ["ts", "mts", "m2ts", "m2t"]
    private static let audioExtensions: Set<String> = [
        "mp3", "m4a", "aac", "wav", "aif", "aiff", "caf", "flac", "oga", "opus"
    ]
    private static let videoExtensions: Set<String> = [
        "mp4", "mov", "m4v", "avi", "mkv", "webm", "mpeg", "mpg", "wmv", "3gp"
    ]

    var symbol: String { self == .audio ? "waveform" : "film" }

    static func detect(fileExtension: String, type: UTType?) -> Self? {
        if audioExtensions.contains(fileExtension) || type?.conforms(to: .audio) == true { return .audio }
        if transportStreams.contains(fileExtension) || videoExtensions.contains(fileExtension)
            || type?.conforms(to: .audiovisualContent) == true { return .video }
        return nil
    }
}

extension FileEntry {
    var mediaKind: MediaKind? {
        guard !isFolder, sourceLanguage == nil else { return nil }
        return MediaKind.detect(fileExtension: url.pathExtension.lowercased(), type: contentType)
    }
}
