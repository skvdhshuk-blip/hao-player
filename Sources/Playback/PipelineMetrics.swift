import os

enum PipelineMetrics {
    static let enhance = OSSignposter(subsystem: "app.hao.HaoPlayer", category: "hao.player.enhance")
    static let present = OSSignposter(subsystem: "app.hao.HaoPlayer", category: "hao.player.present")
}
