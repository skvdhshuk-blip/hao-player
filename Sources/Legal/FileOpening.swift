import AppKit
import Foundation

struct OpenedDrop {
    let bookmark: Data
    let displayName: String
}

enum FileOpening {
    static func bookmark(from url: URL) throws -> Data {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }
        return try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    static func resolve(_ bookmark: Data) throws -> (url: URL, stale: Bool) {
        var stale = false
        let url = try URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        return (url, stale)
    }

    static func displayName(url: URL, suggestedName: String?) -> String {
        let name = url.lastPathComponent
        if isItemProviderTemp(name), let suggestedName, !suggestedName.isEmpty {
            return suggestedName
        }
        return name
    }

    static func isItemProviderTemp(_ name: String) -> Bool {
        name.hasPrefix(".com.apple.Foundation.NSItemProvider")
    }

    static func ingestFileURLs(_ urls: [URL]) throws -> OpenedDrop {
        guard let url = urls.first(where: \.isFileURL) else {
            throw SourceError.emptyDrop
        }
        return OpenedDrop(
            bookmark: try bookmark(from: url),
            displayName: url.lastPathComponent
        )
    }

    static func ingestPasteboard(_ board: NSPasteboard) throws -> OpenedDrop {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true
        ]
        let urls = board.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
        return try ingestFileURLs(urls)
    }
}
