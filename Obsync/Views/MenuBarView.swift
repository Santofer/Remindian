import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var syncManager: SyncManager

    private let menuFont = Font.system(size: 13)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Status section
            HStack {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
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

            Divider()

            // Quick actions
            menuButton("Sync Now", icon: "arrow.triangle.2.circlepath") {
                Task { await syncManager.performSync() }
            }
            .disabled(syncManager.isSyncing || !syncManager.hasRemindersAccess)

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
                        }
                        if result.updated > 0 {
                            Label("\(result.updated)", systemImage: "arrow.triangle.2.circlepath")
                                .foregroundColor(.blue)
                        }
                        if result.deleted > 0 {
                            Label("\(result.deleted)", systemImage: "minus.circle.fill")
                                .foregroundColor(.red)
                        }
                        if result.completionsWrittenBack > 0 {
                            Label("\(result.completionsWrittenBack)", systemImage: "checkmark.circle.fill")
                                .foregroundColor(.purple)
                        }
                        if result.metadataWrittenBack > 0 {
                            Label("\(result.metadataWrittenBack)", systemImage: "pencil.circle.fill")
                                .foregroundColor(.orange)
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

            // Settings & Quit
            menuButton("Open Main Window", icon: "macwindow") {
                openMainWindow()
            }

            menuButton("Settings...", icon: "gear") {
                openSettings()
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
        } else if !syncManager.hasRemindersAccess {
            return .red
        } else if !syncManager.pendingConflicts.isEmpty {
            return .orange
        } else {
            return .green
        }
    }

    private func openMainWindow() {
        NSApplication.shared.activate(ignoringOtherApps: true)

        for window in NSApplication.shared.windows {
            if window.identifier?.rawValue == "main-window" ||
               window.title.contains("Remindian") ||
               String(describing: type(of: window.contentView)).contains("ContentView") {
                window.makeKeyAndOrderFront(nil)
                return
            }
        }

        let contentView = ContentView().environmentObject(SyncManager.shared)
        let hostingController = NSHostingController(rootView: contentView)
        let window = NSWindow(contentViewController: hostingController)
        window.identifier = NSUserInterfaceItemIdentifier("main-window")
        window.title = "Remindian"
        window.setContentSize(NSSize(width: 600, height: 500))
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
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
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    private func openSettings() {
        NSApplication.shared.activate(ignoringOtherApps: true)

        for window in NSApplication.shared.windows {
            if window.identifier?.rawValue == "settings-window" {
                window.makeKeyAndOrderFront(nil)
                return
            }
        }

        let settingsView = SettingsView().environmentObject(SyncManager.shared)
        let hostingController = NSHostingController(rootView: settingsView)
        let window = NSWindow(contentViewController: hostingController)
        window.identifier = NSUserInterfaceItemIdentifier("settings-window")
        window.title = "Settings"
        window.setContentSize(NSSize(width: 550, height: 580))
        window.styleMask = [.titled, .closable, .resizable]
        window.minSize = NSSize(width: 500, height: 450)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }
}

#Preview {
    MenuBarView()
        .environmentObject(SyncManager.shared)
}
