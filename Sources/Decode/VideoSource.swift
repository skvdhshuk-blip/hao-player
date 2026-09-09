import Foundation

enum SourceError: LocalizedError {
    case emptyDrop
    case unsupported(String)
    case notPlayable
    case decodeFailed(String)
    case notOpen
    case scopedAccessFailed

    var errorDescription: String? {
        switch self {
        case .emptyDrop:
            return "没有可打开的文件。"
        case .unsupported(let name):
            return "当前版本暂不支持「\(name)」。可播 mp4 / mov / m4v / mkv / webm / avi。"
        case .notPlayable:
            return "系统无法播放该文件。"
        case .decodeFailed(let detail):
            return detail.isEmpty ? "无法解码该文件。" : "无法解码该文件（\(detail)）。"
        case .notOpen:
            return "还没有打开文件。"
        case .scopedAccessFailed:
            return "无法访问该文件。请用「打开」或重新拖进来。"
        }
    }
}

protocol VideoSource: AnyObject {
    func open(_ url: URL) async throws
    func seek(to time: Double) throws
    func pull() throws -> MediaSample
    var duration: Double { get }
    var hasAudio: Bool { get }
    var sampleRate: Double { get }
}
