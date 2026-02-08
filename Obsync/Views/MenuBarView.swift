import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var syncManager: SyncManager

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Status section
            HStack {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(syncManager.statusMessage)
                    .font(.caption)

                if syncManager.config.dryRunMode {
                    Text("DRY RUN")
                        .font(.caption2)
                        .fontWeight(.bold)
                        .padding(.horizontal, 3)
                        .padding(.vertical, 1)
                        .background(Color.yellow.opacity(0.3))
                        .cornerRadius(3)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            if let lastSync = syncManager.lastSyncDate {
                Text("Last sync: \(lastSync, style: .relative)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 12)
            }

            Divider()

            // Quick actions
            Button(action: {
                Task {
                    await syncManager.performSync()
                }
            }) {
                HStack {
                    Image(systemName: "arrow.triangle.2.circlepath")
                    Text("Sync Now")
                    Spacer()
                    if syncManager.isSyncing {
                        ProgressView()
                            .scaleEffect(0.6)
                    } else {
                        Text("\u{2318}S")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(syncManager.isSyncing || !syncManager.hasRemindersAccess)

            if !syncManager.pendingConflicts.isEmpty {
                Button(action: {
                    openMainWindow()
                }) {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text("\(syncManager.pendingConflicts.count) Conflicts")
                        Spacer()
                    }
                }
            }

            Divider()

            // Last sync results
            if let result = syncManager.lastSyncResult {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Last sync results:")
                        .font(.caption2)
                        .foregroundColor(.secondary)

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
                        if result.created == 0 && result.updated == 0 && result.deleted == 0 && result.completionsWrittenBack == 0 {
                            Text("No changes")
                                .foregroundColor(.secondary)
                        }
                    }
                    .font(.caption)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)

                Divider()
            }

            // Settings & Quit
            Button(action: {
                openMainWindow()
            }) {
                HStack {
                    Image(systemName: "macwindow")
                    Text("Open Main Window")
                    Spacer()
                }
            }

            Button(action: {
                openSettings()
            }) {
                HStack {
                    Image(systemName: "gear")
                    Text("Settings...")
                    Spacer()
                    Text("\u{2318},")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .keyboardShortcut(",", modifiers: .command)

            Divider()

            Button(action: {
                NSApplication.shared.terminate(nil)
            }) {
                HStack {
                    Image(systemName: "power")
                    Text("Quit")
                    Spacer()
                    Text("\u{2318}Q")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .keyboardShortcut("q", modifiers: .command)
        }
        .padding(.vertical, 8)
        .frame(width: 250)
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
               window.title.contains("Obsidian") ||
               String(describing: type(of: window.contentView)).contains("ContentView") {
                window.makeKeyAndOrderFront(nil)
                return
            }
        }

        let contentView = ContentView().environmentObject(SyncManager.shared)
        let hostingController = NSHostingController(rootView: contentView)
        let window = NSWindow(contentViewController: hostingController)
        window.identifier = NSUserInterfaceItemIdentifier("main-window")
        window.title = "Obsync"
        window.setContentSize(NSSize(width: 600, height: 500))
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
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
        window.setContentSize(NSSize(width: 520, height: 480))
        window.styleMask = [.titled, .closable]
        window.center()
        window.makeKeyAndOrderFront(nil)
    }
}

#Preview {
    MenuBarView()
        .environmentObject(SyncManager.shared)
}
