import SwiftUI

struct ContentView: View {
    @EnvironmentObject var syncManager: SyncManager
    @State private var selectedTab = 0

    var body: some View {
        VStack(spacing: 0) {
            HeaderView()

            Divider()

            if !syncManager.hasRemindersAccess {
                PermissionRequestView()
            } else if syncManager.config.vaultPath.isEmpty {
                SetupWizardView()
            } else {
                MainDashboardView()
            }
        }
        .frame(minWidth: 600, minHeight: 500)
        .alert("Error", isPresented: $syncManager.showError) {
            Button("OK") { }
        } message: {
            Text(syncManager.errorMessage)
        }
    }
}

// MARK: - Header

struct HeaderView: View {
    @EnvironmentObject var syncManager: SyncManager

    var body: some View {
        HStack {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.title)
                .foregroundColor(.accentColor)

            VStack(alignment: .leading) {
                Text("Obsidian \u{2194} Reminders Sync")
                    .font(.headline)

                HStack(spacing: 4) {
                    Text(syncManager.statusMessage)
                        .font(.caption)
                        .foregroundColor(.secondary)

                    if syncManager.config.dryRunMode {
                        Text("DRY RUN")
                            .font(.caption2)
                            .fontWeight(.bold)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.yellow.opacity(0.3))
                            .cornerRadius(3)
                    }
                }
            }

            Spacer()

            if syncManager.isSyncing {
                ProgressView()
                    .scaleEffect(0.7)
            } else {
                Button(action: {
                    Task {
                        await syncManager.performSync()
                    }
                }) {
                    Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(!syncManager.hasRemindersAccess || syncManager.config.vaultPath.isEmpty)
            }
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
    }
}

// MARK: - Permission Request

struct PermissionRequestView: View {
    @EnvironmentObject var syncManager: SyncManager

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "checklist")
                .font(.system(size: 60))
                .foregroundColor(.secondary)

            Text("Reminders Access Required")
                .font(.title2)
                .fontWeight(.semibold)

            Text("This app needs access to your Reminders to sync tasks with Obsidian.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .frame(maxWidth: 400)

            Button("Grant Access") {
                Task {
                    await syncManager.requestRemindersAccess()
                }
            }
            .buttonStyle(.borderedProminent)

            Text("You can also grant access in System Settings \u{2192} Privacy & Security \u{2192} Reminders")
                .font(.caption)
                .foregroundColor(.secondary)

            Spacer()
        }
        .padding()
    }
}

// MARK: - Setup Wizard

struct SetupWizardView: View {
    @EnvironmentObject var syncManager: SyncManager

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "folder.badge.gearshape")
                .font(.system(size: 60))
                .foregroundColor(.secondary)

            Text("Welcome! Let's set up your sync.")
                .font(.title2)
                .fontWeight(.semibold)

            Text("First, select your Obsidian vault folder.")
                .foregroundColor(.secondary)

            Button("Select Obsidian Vault") {
                syncManager.selectVaultPath()
            }
            .buttonStyle(.borderedProminent)

            if !syncManager.config.vaultPath.isEmpty {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text(syncManager.config.vaultPath)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: 400)
            }

            Spacer()
        }
        .padding()
    }
}

// MARK: - Main Dashboard

struct MainDashboardView: View {
    @EnvironmentObject var syncManager: SyncManager

    private func openSettingsWindow() {
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

    var body: some View {
        HSplitView {
            // Left panel - Status & Quick Actions
            VStack(alignment: .leading, spacing: 16) {
                GroupBox("Sync Status") {
                    VStack(alignment: .leading, spacing: 8) {
                        if let date = syncManager.lastSyncDate {
                            HStack {
                                Text("Last sync:")
                                Spacer()
                                Text(date, style: .relative)
                                    .foregroundColor(.secondary)
                            }
                        }

                        if let result = syncManager.lastSyncResult {
                            Divider()
                            HStack {
                                StatBadge(value: result.created, label: "Created", color: .green)
                                StatBadge(value: result.updated, label: "Updated", color: .blue)
                                StatBadge(value: result.deleted, label: "Deleted", color: .red)
                            }

                            if result.completionsWrittenBack > 0 {
                                HStack {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.purple)
                                    Text("\(result.completionsWrittenBack) completed in Obsidian")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }

                            if !result.errors.isEmpty {
                                Divider()
                                Text("\(result.errors.count) errors occurred")
                                    .foregroundColor(.red)
                                    .font(.caption)
                            }

                            if result.isDryRun {
                                Divider()
                                HStack {
                                    Image(systemName: "eye")
                                        .foregroundColor(.yellow)
                                    Text("Dry run - no changes were made")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 8)
                }

                GroupBox("Configuration") {
                    VStack(alignment: .leading, spacing: 8) {
                        ConfigRow(label: "Vault", value: URL(fileURLWithPath: syncManager.config.vaultPath).lastPathComponent)
                        ConfigRow(label: "Auto-sync", value: syncManager.config.enableAutoSync ? "Every \(syncManager.config.syncIntervalMinutes) min" : "Disabled")
                        ConfigRow(label: "Default list", value: syncManager.config.defaultList)
                        ConfigRow(label: "Mappings", value: "\(syncManager.config.listMappings.count) configured")
                        ConfigRow(label: "Completion writeback", value: syncManager.config.enableCompletionWriteback ? "Enabled" : "Disabled")
                    }
                    .padding(.vertical, 8)
                }

                Spacer()

                VStack(spacing: 8) {
                    Button("Open Settings") {
                        openSettingsWindow()
                    }
                    .frame(maxWidth: .infinity)

                    Button("Reset Sync State") {
                        syncManager.resetSyncState()
                    }
                    .frame(maxWidth: .infinity)
                    .foregroundColor(.red)
                }
            }
            .padding()
            .frame(minWidth: 250, maxWidth: 300)

            // Right panel - Tabbed: Conflicts / History
            TabView {
                VStack {
                    if !syncManager.pendingConflicts.isEmpty {
                        ConflictsView()
                    } else {
                        EmptyConflictsView()
                    }
                }
                .tabItem { Label("Conflicts", systemImage: "exclamationmark.triangle") }

                SyncHistoryView()
                    .tabItem { Label("History", systemImage: "clock") }
            }
            .padding()
            .frame(minWidth: 300)
        }
    }
}

// MARK: - Helper Views

struct StatBadge: View {
    let value: Int
    let label: String
    let color: Color

    var body: some View {
        VStack {
            Text("\(value)")
                .font(.title2)
                .fontWeight(.bold)
                .foregroundColor(color)
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

struct ConfigRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.callout)
    }
}

struct ConflictsView: View {
    @EnvironmentObject var syncManager: SyncManager

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text("\(syncManager.pendingConflicts.count) Conflicts")
                        .font(.headline)
                    Spacer()
                }

                Text("Obsidian is the source of truth. Use 'Use Obsidian' to sync to Reminders.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Divider()

                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(syncManager.pendingConflicts, id: \.task.id) { conflict in
                            ConflictRow(conflict: conflict)
                        }
                    }
                }
            }
            .padding()
        } label: {
            Text("Pending Conflicts")
        }
    }
}

struct ConflictRow: View {
    let conflict: SyncEngine.SyncConflict
    @EnvironmentObject var syncManager: SyncManager

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(conflict.task.title)
                .fontWeight(.medium)
                .lineLimit(1)

            Button("Use Obsidian Version") {
                syncManager.resolveConflict(conflict, choice: .useObsidian)
            }
            .buttonStyle(.bordered)
        }
        .padding(8)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }
}

struct EmptyConflictsView: View {
    var body: some View {
        GroupBox("Activity") {
            VStack(spacing: 12) {
                Spacer()
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 40))
                    .foregroundColor(.green)
                Text("No conflicts")
                    .font(.headline)
                Text("Everything is in sync!")
                    .foregroundColor(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(SyncManager.shared)
}
