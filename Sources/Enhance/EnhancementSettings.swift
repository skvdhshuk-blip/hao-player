struct EnhancementSettings: Equatable {
    var anime4KEnabled: Bool = true
    var anime4KPreset: Anime4KPreset = .fastA
    var interpolationEnabled: Bool = false

    enum Anime4KPreset: String, CaseIterable {
        case fastA
        case fastB
        case fastC
        case hqA
        case hqB
        case hqC
    }
}
