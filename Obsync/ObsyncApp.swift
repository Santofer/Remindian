import SwiftUI
import EventKit

@main
struct ObsyncApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var syncManager = SyncManager.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(syncManager)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)

        Settings {
            SettingsView()
                .environmentObject(syncManager)
        }

        MenuBarExtra {
            MenuBarView()
                .environmentObject(syncManager)
        } label: {
            let symbolName = syncManager.isSyncing
                ? "arrow.triangle.2.circlepath.circle.fill"
                : "checkmark.circle.fill"
            let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
            let nsImage = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Obsync")?
                .withSymbolConfiguration(config)
            Image(nsImage: nsImage ?? NSImage())
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Apply dock icon visibility setting
        updateDockIconVisibility()

        // Apply forced dark icon if configured
        SyncManager.shared.updateAppIcon()

        // Request notification permission
        NotificationService.shared.requestPermission()

        // Resolve vault bookmark for sandbox access
        _ = SyncManager.shared.resolveVaultBookmark()

        // Register global hotkey if enabled
        SyncManager.shared.updateHotKey()

        // Request Reminders access on launch
        Task {
            await SyncManager.shared.requestRemindersAccess()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false // Keep running in menu bar
    }

    func updateDockIconVisibility() {
        let config = SyncConfiguration.load()
        if config.hideDockIcon {
            NSApp.setActivationPolicy(.accessory)
        } else {
            NSApp.setActivationPolicy(.regular)
        }
    }
}
