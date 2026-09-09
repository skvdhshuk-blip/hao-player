import SwiftUI

struct WindowActionBinder: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onReceive(NotificationCenter.default.publisher(for: .reopenPlayerWindow)) { _ in
                openWindow(id: WindowID.player)
            }
            .onReceive(NotificationCenter.default.publisher(for: .openLicensesWindow)) { _ in
                openWindow(id: WindowID.licenses)
            }
    }
}
