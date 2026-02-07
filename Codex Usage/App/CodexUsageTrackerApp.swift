import SwiftUI

@main
struct CodexUsageTrackerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // This app is menu bar only, no windows by default
        Settings {
            SettingsView()
        }
    }
}
