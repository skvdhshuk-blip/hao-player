import Foundation

final class InterpolationRuntime {
    private static let slowLimit = 8
    private static let slowRatio = 0.8

    private let make: (InterpolationMode) -> FrameProcessor
    private var requested: InterpolationMode = .off
    private(set) var active: InterpolationMode = .off
    private(set) var interpolator: FrameProcessor
    private var slowStreak = 0

    init(make: @escaping (InterpolationMode) -> FrameProcessor) {
        self.make = make
        self.interpolator = make(.off)
    }

    func setRequested(_ mode: InterpolationMode) {
        guard mode != requested else { return }
        requested = mode
        install(mode)
    }

    func restoreRequested() {
        install(requested)
    }

    func reset() {
        interpolator.reset()
        slowStreak = 0
    }

    func process(_ frame: VideoFrame) -> [VideoFrame] {
        while true {
            do {
                return try interpolator.process(frame)
            } catch {
                guard downgrade() else { return [frame] }
            }
        }
    }

    func noteProcessDuration(_ elapsed: TimeInterval, sourceInterval: TimeInterval) {
        let budget = sourceInterval > 0 ? sourceInterval : 1.0 / 24.0
        if elapsed > budget {
            _ = downgrade()
            return
        }
        if elapsed > budget * Self.slowRatio {
            slowStreak += 1
        } else {
            slowStreak = 0
        }
        if slowStreak >= Self.slowLimit {
            slowStreak = 0
            _ = downgrade()
        }
    }

    private func downgrade() -> Bool {
        let next: InterpolationMode
        switch active {
        case .quality:
            next = .fast
        case .fast:
            next = .off
        case .off:
            return false
        }
        install(next)
        return true
    }

    private func install(_ mode: InterpolationMode) {
        active = mode
        interpolator = make(mode)
        interpolator.reset()
        slowStreak = 0
    }
}
