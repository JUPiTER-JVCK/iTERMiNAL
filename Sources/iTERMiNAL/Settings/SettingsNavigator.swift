import Foundation

/// Opens the Settings window on a particular page.
///
/// The Settings scene builds its view itself and takes no arguments, so a
/// request has to wait where the view will find it: when the window is not open
/// yet, the view reads it as it appears; when it is, the notification moves it.
/// Whoever asks still opens the window — this only says which page.
enum SettingsNavigator {
    static let didRequest = Notification.Name("iTERMiNAL.SettingsSectionRequested")

    private(set) static var pending: SettingsSection?

    static func request(_ section: SettingsSection) {
        pending = section
        NotificationCenter.default.post(name: didRequest, object: nil)
    }

    /// The page asked for, once. Taking it clears it, so a window opened later
    /// by hand does not jump somewhere.
    static func take() -> SettingsSection? {
        defer { pending = nil }
        return pending
    }
}
