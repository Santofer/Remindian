import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var syncManager: SyncManager
    @StateObject private var updater = UpdaterService.shared

    private let menuFont = Font.system(size: 13)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Status section
            HStack {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                    .help(statusTooltip)
                Text(syncManager.statusMessage)
                    .font(menuFont)

                if syncManager.config.dryRunMode {
                    Text("DRY RUN")
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 3)
                        .padding(.vertical, 1)
                        .background(Color.yellow.opacity(0.3))
                        .cornerRadius(3)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)

            if let lastSync = syncManager.lastSyncDate {
                Text("Last sync: \(lastSync, style: .relative)")
                    .font(menuFont)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 4)
            }

            // Multi-profile indicator: "Sync Now" runs every enabled profile.
            if syncManager.profileStore.profiles.count > 1 {
                Text("\(syncManager.profileStore.enabledProfiles.count) of \(syncManager.profileStore.profiles.count) sync profiles enabled")
                    .font(menuFont)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 4)
            }

            Divider()

            // Quick actions
            if syncManager.isSyncing {
                menuButton("Stop Sync", icon: "stop.fill") {
                    syncManager.cancelSync()
                }
                .foregroundColor(.red)
            } else {
                menuButton("Sync Now", icon: "arrow.triangle.2.circlepath") {
                    Task { await syncManager.performSync() }
                }
                .disabled(!syncManager.hasDestinationAccess)
            }

            if !syncManager.pendingConflicts.isEmpty {
                menuButton("\(syncManager.pendingConflicts.count) Conflicts", icon: "exclamationmark.triangle.fill") {
                    openMainWindow()
                }
            }

            Divider()

            // Last sync results
            if let result = syncManager.lastSyncResult {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Last sync results:")
                        .font(menuFont)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: 12) {
                        if result.created > 0 {
                            Label("\(result.created)", systemImage: "plus.circle.fill")
                                .foregroundColor(.green)
                                .help("Created in Reminders")
                        }
                        if result.updated > 0 {
                            Label("\(result.updated)", systemImage: "arrow.triangle.2.circlepath")
                                .foregroundColor(.blue)
                                .help("Updated in Reminders")
                        }
                        if result.deleted > 0 {
                            Label("\(result.deleted)", systemImage: "minus.circle.fill")
                                .foregroundColor(.red)
                                .help("Deleted from Reminders")
                        }
                        if result.completionsWrittenBack > 0 {
                            Label("\(result.completionsWrittenBack)", systemImage: "checkmark.circle.fill")
                                .foregroundColor(.purple)
                                .help("Completed in Obsidian (writeback)")
                        }
                        if result.metadataWrittenBack > 0 {
                            Label("\(result.metadataWrittenBack)", systemImage: "pencil.circle.fill")
                                .foregroundColor(.orange)
                                .help("Metadata written back to Obsidian")
                        }
                        if result.created == 0 && result.updated == 0 && result.deleted == 0 && result.completionsWrittenBack == 0 && result.metadataWrittenBack == 0 {
                            Text("No changes")
                                .foregroundColor(.secondary)
                        }
                    }
                    .font(menuFont)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)

                Divider()
            }

            // Update available banner
            if updater.updateAvailable {
                menuButton("Update Available: \(updater.latestVersion)", icon: "arrow.up.circle.fill") {
                    updater.downloadUpdate()
                }
                .foregroundColor(.blue)

                Divider()
            }

            // Settings & Quit.
            // Note: "Settings…" used to live next to "Open Main Window" but
            // since v5.4.0 unified Settings into the main window's TabView,
            // both items showed the exact same window. Removed the redundant
            // entry per #62.2 (fnsign).
            menuButton("Open Main Window", icon: "macwindow") {
                openMainWindow()
            }

            menuButton("About Remindian", icon: "info.circle") {
                openAboutWindow()
            }

            Divider()

            menuButton("Quit Remindian", icon: "power") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(.vertical, 4)
        .frame(width: 250)
    }

    /// Consistent menu-style button with system font
    private func menuButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .frame(width: 16)
                Text(title)
                Spacer()
            }
            .font(menuFont)
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var statusColor: Color {
        if syncManager.isSyncing {
            return .blue
        } else if !syncManager.hasDestinationAccess {
            return .red
        } else if !syncManager.pendingConflicts.isEmpty {
            return .orange
        } else {
            return .green
        }
    }

    private var statusTooltip: String {
        if syncManager.isSyncing {
            return "Blue: Sync in progress"
        } else if !syncManager.hasDestinationAccess {
            return "Red: No destination access — check configuration in Settings"
        } else if !syncManager.pendingConflicts.isEmpty {
            return "Orange: Unresolved conflicts — open main window to resolve"
        } else {
            return "Green: Everything is synced and up to date"
        }
    }

    private func openMainWindow() {
        // Honor the user's "Hide dock icon" preference (#62.1). Forcing
        // `.regular` here previously made the dock icon reappear and persist
        // even after the window closed. `.accessory` apps can still display
        // and key windows just fine via `makeKeyAndOrderFront` + `activate`.
        if !syncManager.config.hideDockIcon {
            NSApp.setActivationPolicy(.regular)
        }
        NSApplication.shared.activate(ignoringOtherApps: true)

        // Find the main window by identifier (tagged in AppDelegate at launch).
        // This is reliable regardless of window level, visibility, or macOS version.
        if let mainWindow = NSApplication.shared.windows.first(where: {
            $0.identifier?.rawValue == "main-window"
        }) {
            mainWindow.makeKeyAndOrderFront(nil)
            return
        }

        // Window was released or never tagged — recreate it programmatically.
        let contentView = ContentView().environmentObject(SyncManager.shared)
        let hostingController = NSHostingController(rootView: contentView)
        let window = NSWindow(contentViewController: hostingController)
        window.identifier = NSUserInterfaceItemIdentifier("main-window")
        window.title = "Remindian"
        window.setContentSize(NSSize(width: 900, height: 650))
        window.styleMask = [.titled, .closable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    private func openAboutWindow() {
        NSApplication.shared.activate(ignoringOtherApps: true)

        for window in NSApplication.shared.windows {
            if window.identifier?.rawValue == "about-window" {
                window.makeKeyAndOrderFront(nil)
                return
            }
        }

        let aboutView = AboutView()
        let hostingController = NSHostingController(rootView: aboutView)
        let window = NSWindow(contentViewController: hostingController)
        window.identifier = NSUserInterfaceItemIdentifier("about-window")
        window.title = "About Remindian"
        window.setContentSize(NSSize(width: 320, height: 480))
        window.styleMask = [.titled, .closable]
        if #available(macOS 26, *) {
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
        }
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    private func openSettings() {
        openNativeSettingsWindow()
    }
}

#Preview {
    MenuBarView()
        .environmentObject(SyncManager.shared)
}
