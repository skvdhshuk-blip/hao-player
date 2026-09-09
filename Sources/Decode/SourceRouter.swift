import Foundation

enum MediaKind: Equatable {
    case avFoundation
    case ffmpeg
    case unsupported
}

enum SourceRouter {
    static let ffmpegExtensions: Set<String> = ["mkv", "webm", "avi", "ts", "m2ts"]

    static func kind(for url: URL) -> MediaKind {
        if let kind = kind(forExtension: url.pathExtension) {
            return kind
        }
        return kindBySniffing(url) ?? .unsupported
    }

    static func kind(forExtension ext: String) -> MediaKind? {
        let ext = ext.lowercased()
        if AVFoundationSource.supportedExtensions.contains(ext) {
            return .avFoundation
        }
        if ffmpegExtensions.contains(ext) {
            return .ffmpeg
        }
        return nil
    }

    static func kindBySniffing(_ url: URL) -> MediaKind? {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 16), data.count >= 4 else {
            return nil
        }
        let bytes = [UInt8](data)
        if bytes[0] == 0x1A, bytes[1] == 0x45, bytes[2] == 0xDF, bytes[3] == 0xA3 {
            return .ffmpeg
        }
        if bytes.count >= 8, bytes[4] == 0x66, bytes[5] == 0x74, bytes[6] == 0x79, bytes[7] == 0x70 {
            return .avFoundation
        }
        if bytes.count >= 12,
           bytes[0] == 0x52, bytes[1] == 0x49, bytes[2] == 0x46, bytes[3] == 0x46,
           bytes[8] == 0x41, bytes[9] == 0x56, bytes[10] == 0x49, bytes[11] == 0x20 {
            return .ffmpeg
        }
        return nil
    }
}
