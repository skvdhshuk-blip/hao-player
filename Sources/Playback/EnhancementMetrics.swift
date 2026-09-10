import Foundation
import Darwin
import CoreVideo
import QuartzCore

struct TimingSummary: Codable, Equatable, Sendable {
    var count = 0
    var meanMS = 0.0
    var p95MS = 0.0
    var maxMS = 0.0
}

struct EnhancementReport: Codable, Equatable, Sendable {
    var schemaVersion = 1
    var purpose = "playback"
    var epoch = 0
    var settings = EnhancementSettings()
    var status = EnhancementStatus()
    var gpu = GPUContext.shared.device.name
    var memoryBytes = ProcessInfo.processInfo.physicalMemory
    var operatingSystem = ProcessInfo.processInfo.operatingSystemVersionString
    var lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
    var submitted = 0
    var presentationCallbacks = 0
    var unpresentedCallbacks = 0
    var consecutiveUnpresented = 0
    var staleCallbacks = 0
    var outputWidth = 0
    var outputHeight = 0
    var sourceWidth = 0
    var sourceHeight = 0
    var sourceFPS = 0.0
    var measuredSeconds = 0.0
    var generated = 0
    var generatedInterpolated = 0
    var presented = 0
    var presentedInterpolated = 0
    var presentedEnhanced = 0
    var droppedSource = 0
    var droppedLate = 0
    var droppedDisplay = 0
    var queueDepth = 0
    var maxQueueDepth = 0
    var firstProcessMS: Double?
    var warmupSeconds = 2.0
    var stages: [String: TimingSummary] = [:]
    var displayFPS: Double { measuredSeconds > 0 ? Double(presented) / measuredSeconds : 0 }
    var interpolatedShare: Double { presented > 0 ? Double(presentedInterpolated) / Double(presented) : 0 }
    var dropRate: Double {
        let missing = droppedLate + droppedDisplay + droppedSource * (settings.interpolation == .off ? 1 : 2)
        let total = presented + missing
        return total > 0 ? Double(missing) / Double(total) : 0
    }
}

private struct TimingHistogram {
    var count = 0
    var sum = 0.0
    var maximum = 0.0
    var bins: [Int: Int] = [:]
    mutating func add(_ seconds: Double) {
        count += 1
        sum += seconds
        maximum = max(maximum, seconds)
        // 0.1 ms bins through 10 seconds; slower values share an overflow bin.
        bins[min(100_000, Int(max(0, seconds) * 10_000)), default: 0] += 1
    }
    var summary: TimingSummary {
        var cumulative = 0
        var percentile = 0.0
        for key in bins.keys.sorted() {
            cumulative += bins[key, default: 0]
            if cumulative >= Int(ceil(Double(count) * 0.95)) {
                percentile = key == 100_000 ? maximum : Double(key + 1) / 10_000
                break
            }
        }
        return TimingSummary(count: count, meanMS: count > 0 ? sum / Double(count) * 1000 : 0,
                             p95MS: percentile * 1000, maxMS: maximum * 1000)
    }
}

/// Small, bounded samples; decode, GPU callbacks and UI never share the processor lock.
final class EnhancementMetrics: @unchecked Sendable {
    private let lock = NSLock()
    private var report = EnhancementReport()
    private var samples: [String: TimingHistogram] = [:]
    private var sourceDuration = 0.0
    private var sourceCount = 0
    private var previousPTS: Double?
    private var playing = false
    private var start: Double?
    private var measuredStart: Double?
    private var elapsed = 0.0
    private var slowStreak = 0
    private var healthyStreak = 0

    func reset(epoch: Int, settings: EnhancementSettings, purpose: String = "playback") {
        lock.withLock {
            report = EnhancementReport(purpose: purpose, epoch: epoch, settings: settings)
            report.status.anime4KPhase = settings.anime4KEnabled ? .preparing : .off
            report.status.interpolationPhase = settings.interpolation == .off ? .off : .preparing
            samples = [:]
            sourceDuration = 0
            sourceCount = 0
            previousPTS = nil
            start = nil
            measuredStart = nil
            elapsed = 0
            slowStreak = 0
            healthyStreak = 0
        }
    }

    func setPlaying(_ value: Bool, now: Double = CACurrentMediaTime()) {
        lock.withLock {
            guard playing != value else { return }
            if let measuredStart { elapsed += max(0, now - measuredStart) }
            measuredStart = nil
            playing = value
            if value, let start, now >= start + report.warmupSeconds { measuredStart = now }
        }
    }

    private func measuring(_ now: Double) -> Bool {
        guard playing, let start, now >= start + report.warmupSeconds else { return false }
        if measuredStart == nil { measuredStart = now }
        return true
    }

    func sourceFrame(_ input: VideoFrame) {
        lock.withLock {
            guard input.trace.epoch == report.epoch else { return }
            report.sourceWidth = CVPixelBufferGetWidth(input.pixelBuffer)
            report.sourceHeight = CVPixelBufferGetHeight(input.pixelBuffer)
            let interval = previousPTS.map { input.pts - $0 } ?? input.duration
            previousPTS = input.pts
            if interval > 0 {
                sourceDuration += interval
                sourceCount += 1
                report.sourceFPS = Double(sourceCount) / sourceDuration
            }
        }
    }

    func processed(_ frames: [VideoFrame], input: VideoFrame, times: [String: Double], now: Double = CACurrentMediaTime()) {
        lock.withLock {
            guard input.trace.epoch == report.epoch, report.status.failure == nil else { return }
            if report.firstProcessMS == nil { report.firstProcessMS = (times["total"] ?? 0) * 1000 }
            if start == nil, playing { start = now }
            guard measuring(now) else { return }
            report.generated += frames.count
            report.generatedInterpolated += frames.filter { $0.trace.interpolated }.count
            for (name, value) in times { record(name, seconds: value) }
            if let total = times["total"], input.duration > 0 {
                if total > input.duration { slowStreak += 1; healthyStreak = 0 }
                else { slowStreak = 0; healthyStreak += 1 }
                if slowStreak >= 8 { report.status.performanceLimited = true }
                if healthyStreak >= 48 { report.status.performanceLimited = false }
            }
        }
    }

    func queued(epoch: Int, count: Int) {
        lock.withLock {
            guard epoch == report.epoch else { return }
            report.queueDepth = count
            report.maxQueueDepth = max(report.maxQueueDepth, count)
        }
    }

    func completedCycle(epoch: Int, cleanup: Double, total: Double, now: Double = CACurrentMediaTime()) {
        lock.withLock {
            guard epoch == report.epoch, report.status.failure == nil, measuring(now) else { return }
            record("temporaryCleanup", seconds: cleanup)
            record("processingWithCleanup", seconds: total)
        }
    }

    func submitted(_ frame: VideoFrame) {
        lock.withLock { if frame.trace.epoch == report.epoch { report.submitted += 1 } }
    }

    func displayed(_ frame: VideoFrame, at time: Double, gpuSeconds: Double = 0) {
        lock.withLock {
            guard frame.trace.epoch == report.epoch else { report.staleCallbacks += 1; return }
            report.presentationCallbacks += 1
            guard report.status.failure == nil else { return }
            guard time > 0 else {
                report.unpresentedCallbacks += 1
                report.consecutiveUnpresented += 1
                if measuring(CACurrentMediaTime()) { report.droppedDisplay += 1 }
                return
            }
            report.consecutiveUnpresented = 0
            report.outputWidth = CVPixelBufferGetWidth(frame.pixelBuffer)
            report.outputHeight = CVPixelBufferGetHeight(frame.pixelBuffer)
            if frame.trace.anime4K { report.status.anime4KEnabled = true; report.status.anime4KPhase = .active }
            if frame.trace.interpolated {
                report.status.interpolation = frame.trace.interpolation
                report.status.interpolationPhase = .active
            }
            if start == nil, playing { start = time }
            guard measuring(time) else { return }
            report.presented += 1
            if frame.trace.interpolated { report.presentedInterpolated += 1 }
            if frame.trace.anime4K { report.presentedEnhanced += 1 }
            if frame.trace.queuedAt > 0 { record("queueToScreen", seconds: max(0, time - frame.trace.queuedAt)) }
            if gpuSeconds > 0 { record("displayGPU", seconds: gpuSeconds) }
        }
    }

    func droppedSource(epoch: Int, now: Double = CACurrentMediaTime()) {
        lock.withLock {
            guard epoch == report.epoch, measuring(now) else { return }
            report.droppedSource += 1
            report.status.performanceLimited = true
        }
    }

    func dropped(_ frames: [VideoFrame], now: Double = CACurrentMediaTime()) {
        lock.withLock {
            guard measuring(now) else { return }
            report.droppedLate += frames.filter { $0.trace.epoch == report.epoch }.count
            if !frames.isEmpty { report.status.performanceLimited = true }
        }
    }

    func fail(_ failure: EnhancementFailure, epoch: Int) {
        lock.withLock {
            guard epoch == report.epoch else { return }
            report.status.failure = failure
            if failure.stage == .anime4K { report.status.anime4KPhase = .failed; report.status.anime4KEnabled = false }
            if failure.stage == .interpolation { report.status.interpolationPhase = .failed; report.status.interpolation = .off }
        }
    }

    func snapshot(now: Double = CACurrentMediaTime()) -> EnhancementReport {
        lock.withLock {
            var value = report
            value.measuredSeconds = elapsed + (measuredStart.map { max(0, now - $0) } ?? 0)
            if value.status.performanceLimited {
                if value.status.anime4KPhase == .active { value.status.anime4KPhase = .slow }
                if value.status.interpolationPhase == .active { value.status.interpolationPhase = .slow }
            }
            for (key, histogram) in samples { value.stages[key] = histogram.summary }
            return value
        }
    }

    private func record(_ name: String, seconds: Double) {
        samples[name, default: TimingHistogram()].add(seconds)
    }
}

func currentProcessFootprint() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? info.phys_footprint : 0
}
