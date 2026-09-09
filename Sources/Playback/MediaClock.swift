enum MediaClock {
    static func now(paused: Bool, frozen: Double, anchor: Double, elapsed: Double, duration: Double) -> Double {
        let raw = paused ? frozen : anchor + elapsed
        let clipped = max(0, raw)
        if duration > 0 {
            return min(clipped, duration)
        }
        return clipped
    }
}
