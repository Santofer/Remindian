import SwiftUI
import EventKit
import ServiceManagement

@main
struct RemindianApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var syncManager = SyncManager.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(syncManager)
                .onOpenURL { url in
                    OAuthCallbackHandler.shared.handle(url: url)
                }
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
                .onOpenURL { url in
                    OAuthCallbackHandler.shared.handle(url: url)
                }
        } label: {
            let count = syncManager.config.showMenuBarTaskCount ? syncManager.agenda.count : 0
            Image(nsImage: RemindianApp.menuBarImage(count: count, syncing: syncManager.isSyncing))
        }
        // Render the menu as a real SwiftUI panel. The default `.menu` style
        // is a native NSMenu that flattens multi-element rows (the Today list,
        // quick-add field, etc.) into separate stacked items — `.window` lays
        // them out exactly as designed (one row = one line).
        .menuBarExtraStyle(.window)
    }

    /// Compose the menu-bar status icon, optionally with a due/overdue count
    /// drawn beside it. Returns a template image so the menu bar tints it for
    /// light/dark automatically. (menu-bar badge)
    static func menuBarImage(count: Int, syncing: Bool) -> NSImage {
        let symbolName: String
        if syncing {
            symbolName = "arrow.triangle.2.circlepath.circle.fill"
        } else if count > 0 {
            symbolName = "list.bullet.circle.fill"   // pending tasks
        } else {
            symbolName = "checkmark.circle.fill"      // all clear
        }
        let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Remindian")?
            .withSymbolConfiguration(cfg) ?? NSImage()

        guard count > 0, !syncing else {
            symbol.isTemplate = true
            return symbol
        }

        let text = "\(count)" as NSString
        let font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let textSize = text.size(withAttributes: attrs)
        let gap: CGFloat = 2
        let h = max(symbol.size.height, textSize.height)
        let w = symbol.size.width + gap + textSize.width

        let img = NSImage(size: NSSize(width: w, height: h))
        img.lockFocus()
        symbol.draw(in: NSRect(x: 0, y: (h - symbol.size.height) / 2,
                               width: symbol.size.width, height: symbol.size.height))
        text.draw(at: NSPoint(x: symbol.size.width + gap, y: (h - textSize.height) / 2),
                  withAttributes: attrs)
        img.unlockFocus()
        img.isTemplate = true   // alpha mask → menu bar tints it light/dark
        return img
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Skip all app initialization when running under a test host.
        // Tests should not trigger permission prompts, syncs, or side effects.
        guard NSClassFromString("XCTestCase") == nil else { return }

        // Each step is isolated so one failure doesn't crash the whole app.
        // Subsystem failures are logged but non-fatal.

        safeInit("Dock icon visibility") { updateDockIconVisibility() }
        safeInit("App icon") { SyncManager.shared.updateAppIcon() }
        safeInit("Notification permission") { NotificationService.shared.requestPermission() }
        safeInit("Vault bookmark") { _ = SyncManager.shared.resolveVaultBookmark() }
        safeInit("MTN bookmark") { _ = TaskNotesSource.resolveMtnBookmark() }
        safeInit("Global hotkey") { SyncManager.shared.updateHotKey() }
        safeInit("File watcher") { SyncManager.shared.updateFileWatcher() }
        safeInit("Auto-updater") { _ = UpdaterService.shared }

        // Request destination access on launch + auto-sync if configured.
        // performLaunchSyncIfReady combines both so runtime config changes
        // (which call requestDestinationAccess() directly) don't trigger
        // a sync as a side effect. See #62.5.
        Task {
            await SyncManager.shared.performLaunchSyncIfReady()
            // Populate the Today agenda so the menu-bar count badge shows on
            // launch even if sync-on-launch is off. Non-force: the 10s throttle
            // dedups it when the launch sync already refreshed. (menu-bar badge)
            await SyncManager.shared.refreshAgenda()
        }

        // Reopen the floating pinned-tasks window if it was open at last quit.
        safeInit("Pinned tasks window") {
            DispatchQueue.main.async {
                PinnedTasksWindowController.shared.restoreIfPreviouslyOpen()
            }
        }

        // Keep the main SwiftUI window alive when closed (hide instead of release)
        // so we can reshow it from the menu bar without losing the Liquid Glass layout.
        // Tag it with an identifier so openMainWindow() can find it reliably
        // regardless of window level or visibility state.
        safeInit("Window lifecycle") {
            DispatchQueue.main.async {
                for window in NSApp.windows where window.level == .normal {
                    window.isReleasedWhenClosed = false
                    if window.identifier == nil {
                        window.identifier = NSUserInterfaceItemIdentifier("main-window")
                    }
                }
            }
        }

        // macOS 26+ (Tahoe): Configure main window for Liquid Glass
        if #available(macOS 26, *) {
            safeInit("Liquid Glass window") {
                DispatchQueue.main.async {
                    for window in NSApp.windows {
                        window.titlebarAppearsTransparent = true
                        window.titleVisibility = .hidden
                        window.styleMask.insert(.fullSizeContentView)
                    }
                }
            }
        }
    }

    /// Run an initialization step safely. If the block crashes the process, at least the
    /// debug log will show which step was attempted last.
    private func safeInit(_ label: String, _ block: () -> Void) {
        debugLog("[AppDelegate] Starting: \(label)")
        block()
        debugLog("[AppDelegate] Completed: \(label)")
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
