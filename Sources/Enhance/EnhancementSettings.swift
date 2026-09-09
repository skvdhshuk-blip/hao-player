enum InterpolationMode: String, CaseIterable {
    case off
    case fast
    case quality
}

struct EnhancementSettings: Equatable {
    var anime4KEnabled: Bool = true
    var anime4KPreset: Anime4KPreset = .fastA
    var interpolation: InterpolationMode = .off

    enum Anime4KPreset: String, CaseIterable {
        case fastA
        case fastB
        case fastC
        case hqA
        case hqB
        case hqC
    }
}
