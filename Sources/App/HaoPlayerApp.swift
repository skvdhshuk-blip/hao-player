import SwiftUI

@main
struct HaoPlayerApp: App {
    @StateObject private var engine = PlaybackEngine()

    var body: some Scene {
        Window("Hao Player", id: WindowID.player) {
            PlayerScreen()
                .environmentObject(engine)
#if ENHANCEMENT_ACCEPTANCE
                .onAppear { EnhancementAcceptance.shared.start() }
#endif
        }
        .defaultSize(width: 960, height: 540)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("打开…") {
                    engine.presentOpenPanel()
                }
                .keyboardShortcut("o", modifiers: .command)
                Button("播放/暂停") {
                    engine.togglePlay()
                }
                .keyboardShortcut(.space, modifiers: [])
                Button("后退 5 秒") { engine.skip(by: -5) }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                    .disabled(engine.mode == .idle)
                Button("前进 5 秒") { engine.skip(by: 5) }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                    .disabled(engine.mode == .idle)
                Button(engine.isFullScreen ? "退出全屏" : "全屏") {
                    engine.toggleFullScreen()
                }
                .keyboardShortcut("f", modifiers: [.control, .command])
            }
            CommandGroup(after: .windowArrangement) {
                Button("播放器") {
                    NotificationCenter.default.post(name: .reopenPlayerWindow, object: nil)
                }
                .keyboardShortcut("0", modifiers: .command)
                Button("许可证") {
                    NotificationCenter.default.post(name: .openLicensesWindow, object: nil)
                }
            }
        }

        Window("许可证", id: WindowID.licenses) {
            LicensesView()
        }
        .defaultSize(width: 560, height: 420)
        .windowResizability(.contentMinSize)
    }
}
