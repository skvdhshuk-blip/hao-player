import SwiftUI

struct PlayerScreen: View {
    @EnvironmentObject private var engine: PlaybackEngine

    var body: some View {
        ZStack {
            Color.black
            switch engine.mode {
            case .idle:
                emptyState
            case .playing:
                MetalView(presenter: engine.session.presenter)
                    .ignoresSafeArea()
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
                }
            }
        }
        .frame(minWidth: 720, minHeight: 420)
        .background(WindowActionBinder())
        .onAppear {
            Task { @MainActor in
                await engine.restoreIfNeeded()
            }
        }
        .onDisappear {
            engine.persistResume()
        }
        .onOpenURL { url in
            Task { @MainActor in
                await engine.openFile(url)
            }
        }
        .onKeyPress(.leftArrow) {
            engine.skip(by: -5)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            engine.skip(by: 5)
            return .handled
        }
        .alert("无法播放", isPresented: Binding(
            get: { engine.errorMessage != nil },
            set: { if !$0 { engine.errorMessage = nil } }
        )) {
            Button("好", role: .cancel) { engine.errorMessage = nil }
        } message: {
            Text(engine.errorMessage ?? "")
        }
        .navigationTitle(engine.title.isEmpty ? "Hao Player" : engine.title)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "film")
                .font(.system(size: 36, weight: .regular))
                .foregroundStyle(.secondary)
            Text("打开文件或拖进来")
                .font(.title3)
            Text("mp4 / mov / m4v / mkv / webm / avi")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("打开…") {
                engine.presentOpenPanel()
            }
            .keyboardShortcut("o", modifiers: .command)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
