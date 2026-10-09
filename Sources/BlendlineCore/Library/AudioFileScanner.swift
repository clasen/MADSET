import Foundation

public enum AudioFileScanner {
    public static let supportedExtensions: Set<String> = ["mp3", "aif", "aiff", "wav", "flac", "m4a"]

    /// Expands dropped files and folders into audio files. Folder contents are sorted by path;
    /// the order of the dropped items is kept.
    public static func audioFiles(in urls: [URL]) -> [URL] {
        var result: [URL] = []
        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsPackageDescendants])
                let files = (enumerator?.allObjects as? [URL] ?? []).filter(isAudio)
                result += files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            } else if isAudio(url) {
                result.append(url)
            }
        }
        return result
    }

    private static func isAudio(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }
}
