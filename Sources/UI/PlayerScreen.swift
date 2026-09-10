import AppKit
import SwiftUI

struct PlayerScreen: View {
    @EnvironmentObject private var engine: PlaybackEngine
    @State private var chromeVisible = true
    @State private var hideChromeTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            Color.black
            switch engine.mode {
            case .idle:
                emptyState
            case .playing:
                MetalView(presenter: engine.session.presenter)
                    .ignoresSafeArea()
                    .onTapGesture {
                        if showsChrome {
                            hideChrome()
                        } else {
                            revealChrome()
                        }
                    }
            }
            FileDropCatcher(
                onOpen: { drop in
                    Task { @MainActor in
                        await engine.openDroppedBookmark(drop)
                    }
                },
                onFail: { engine.errorMessage = $0 }
            )
            .ignoresSafeArea()
            VStack {
                Spacer()
                if engine.mode != .idle {
                    PlayerChrome()
                        .opacity(showsChrome ? 1 : 0)
                        .allowsHitTesting(showsChrome)
                        .onHover { inside in
                            if inside {
                                chromeVisible = true
                                hideChromeTask?.cancel()
                            } else if engine.isPlaying {
                                scheduleHideChrome()
                            }
                        }
                }
            }
        }
        .onContinuousHover { phase in
            if case .active = phase {
                revealChrome()
            }
        }
        .onChange(of: engine.isPlaying) { _, playing in
            if playing {
                revealChrome()
            } else {
                chromeVisible = true
                hideChromeTask?.cancel()
            }
        }
        .onChange(of: engine.isScrubbing) { _, scrubbing in
            if scrubbing {
                chromeVisible = true
                hideChromeTask?.cancel()
            } else {
                revealChrome()
            }
        }
        .animation(.easeOut(duration: 0.2), value: showsChrome)
        .frame(minWidth: 720, minHeight: 420)
        .background(WindowActionBinder())
        .onAppear {
#if !ENHANCEMENT_ACCEPTANCE
            Task { @MainActor in
                await engine.restoreIfNeeded()
            }
#endif
        }
        .onDisappear {
            engine.persistResume()
        }
        .onOpenURL { url in
            Task { @MainActor in
                await engine.openFile(url)
            }
        }
        .alert("无法播放", isPresented: Binding(
            get: { engine.errorMessage != nil },
            set: { if !$0 { engine.errorMessage = nil } }
        )) {
            Button("好", role: .cancel) { engine.errorMessage = nil }
        } message: {
            Text(engine.errorMessage ?? "")
        }
        .sheet(isPresented: $engine.showEnhancementDetails) { EnhancementDetails().environmentObject(engine) }
        .sheet(isPresented: $engine.showImageComparison, onDismiss: { engine.endComparison() }) {
            ImageComparisonView().environmentObject(engine)
        }
        .alert("增强处理失败，播放已暂停", isPresented: Binding(
            get: { engine.enhancementFailure != nil },
            set: { _ in }
        )) {
            Button("重试") { engine.resolveEnhancementFailure(disable: false) }
            if engine.enhancementFailure?.stage != .presentation {
                Button("关闭此功能并继续") { engine.resolveEnhancementFailure(disable: true) }
            }
            Button("保持暂停", role: .cancel) { engine.keepPausedAfterFailure() }
        } message: { Text(engine.enhancementFailure?.errorDescription ?? "") }
        .navigationTitle(engine.title.isEmpty ? "Hao Player" : engine.title)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "film")
                .font(.system(size: 36, weight: .regular))
                .foregroundStyle(.secondary)
            Text("打开文件或拖进来")
                .font(.title3)
            Text("mp4 / mov / m4v / mkv / webm / avi / ts / flv")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("打开…") {
                engine.presentOpenPanel()
            }
            .keyboardShortcut("o", modifiers: .command)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var showsChrome: Bool {
        engine.mode == .idle || chromeVisible || !engine.isPlaying || engine.isScrubbing
    }

    private func revealChrome() {
        chromeVisible = true
        if engine.isFullScreen {
            NSCursor.unhide()
        }
        scheduleHideChrome()
    }

    private func hideChrome() {
        guard engine.isPlaying, !engine.isScrubbing else { return }
        hideChromeTask?.cancel()
        chromeVisible = false
        if engine.isFullScreen {
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }

    private func scheduleHideChrome() {
        hideChromeTask?.cancel()
        guard engine.mode == .playing, engine.isPlaying, !engine.isScrubbing else { return }
        hideChromeTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.4))
            guard !Task.isCancelled else { return }
            hideChrome()
        }
    }
}
