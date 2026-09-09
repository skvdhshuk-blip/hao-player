enum MediaClock {
    static func now(paused: Bool, frozen: Double, anchor: Double, elapsed: Double, duration: Double) -> Double {
        let raw = paused ? frozen : anchor + elapsed
        let clipped = max(0, raw)
        if duration > 0 {
            return min(clipped, duration)
        }
        return clipped
    }

    static func fromAudio(
        origin: Double,
        sampleOrigin: Int64,
        sampleTime: Int64,
        sampleRate: Double,
        duration: Double
    ) -> Double {
        let elapsed = sampleRate > 0 ? Double(sampleTime - sampleOrigin) / sampleRate : 0
        return now(paused: false, frozen: origin, anchor: origin, elapsed: elapsed, duration: duration)
    }
}
