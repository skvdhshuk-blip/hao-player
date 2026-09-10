import Foundation

enum InterpolationMode: String, CaseIterable, Codable, Sendable {
    case off
    case fast
    case quality

    var title: String {
        switch self {
        case .off: return "关"
        case .fast: return "快"
        case .quality: return "高质量"
        }
    }
}

enum EnhancementPhase: String, Codable, Sendable {
    case off, preparing, active, slow, failed

    var title: String {
        switch self {
        case .off: "关"
        case .preparing: "准备中"
        case .active: "已生效"
        case .slow: "性能不足"
        case .failed: "失败"
        }
    }
}

enum EnhancementStage: String, Codable, Sendable {
    case interpolation, anime4K, presentation
    var title: String {
        switch self {
        case .interpolation: "流畅档"
        case .anime4K: "Anime4K"
        case .presentation: "画面显示"
        }
    }
}

struct EnhancementFailure: Error, LocalizedError, Equatable, Codable, Sendable {
    let stage: EnhancementStage
    let message: String
    var errorDescription: String? { "\(stage.title)无法运行：\(message)" }
}

struct EnhancementStatus: Equatable, Codable, Sendable {
    var anime4KEnabled = false
    var interpolation: InterpolationMode = .off
    var anime4KPhase: EnhancementPhase = .off
    var interpolationPhase: EnhancementPhase = .off
    var failure: EnhancementFailure?
    var performanceLimited = false
}

struct EnhancementSettings: Equatable, Codable, Sendable {
    var anime4KEnabled: Bool = true
    var anime4KPreset: Anime4KPreset = .fastA
    var interpolation: InterpolationMode = .off

    enum Anime4KPreset: String, CaseIterable, Codable, Sendable {
        case fastA
        case fastB
        case fastC
        case hqA
        case hqB
        case hqC
    }
}
