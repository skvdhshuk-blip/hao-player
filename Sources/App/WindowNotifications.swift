import Foundation

extension Notification.Name {
    static let reopenPlayerWindow = Notification.Name("hao.player.reopenPlayerWindow")
    static let openLicensesWindow = Notification.Name("hao.player.openLicensesWindow")
}

enum WindowID {
    static let player = "player"
    static let licenses = "licenses"
}
