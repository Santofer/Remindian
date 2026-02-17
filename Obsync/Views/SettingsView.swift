import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var syncManager: SyncManager

    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem {
                    Label("General", systemImage: "gear")
                }
                .tag(0)

            ListMappingsView()
                .tabItem {
                    Label("List Mappings", systemImage: "list.bullet")
                }
                .tag(1)

            AdvancedSettingsView()
                .tabItem {
                    Label("Advanced", systemImage: "wrench.and.screwdriver")
                }
                .tag(2)
        }
        .frame(width: 550, height: 580)
        .padding()
    }
}

// MARK: - General Settings

struct GeneralSettingsView: View {
    @EnvironmentObject var syncManager: SyncManager

    var body: some View {
        ScrollView {
            Form {
                Section {
                    HStack {
                        TextField("Vault Path", text: $syncManager.config.vaultPath)
                            .disabled(true)

                        Button("Browse...") {
                            syncManager.selectVaultPath()
                        }
                    }

                    if !syncManager.config.vaultPath.isEmpty {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text("Vault configured")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                } header: {
                    Text("Obsidian Vault")
                }

                Section {
                    Toggle("Enable automatic sync", isOn: $syncManager.config.enableAutoSync)

                    if syncManager.config.enableAutoSync {
                        Picker("Sync interval", selection: $syncManager.config.syncIntervalMinutes) {
                            Text("1 minute").tag(1)
                            Text("5 minutes").tag(5)
                            Text("15 minutes").tag(15)
                            Text("30 minutes").tag(30)
                            Text("1 hour").tag(60)
                        }
                    }

                    Toggle("Sync on app launch", isOn: $syncManager.config.syncOnLaunch)

                    Toggle("Watch vault for changes (real-time sync)", isOn: $syncManager.config.enableFileWatcher)
                        .onChange(of: syncManager.config.enableFileWatcher) { _ in
                            syncManager.updateFileWatcher()
                        }
                        .help("Automatically sync when markdown files in your vault are modified")

                    Toggle("Include time in due dates", isOn: $syncManager.config.includeDueTime)
                        .help("When disabled, reminders will be all-day tasks without a specific time")

                    Toggle("Sync completion back to Obsidian", isOn: $syncManager.config.enableCompletionWriteback)
                        .help("When enabled, marking a task complete in Reminders will update the checkbox and add a completion date in Obsidian")

                    Toggle("Sync due date changes back to Obsidian", isOn: $syncManager.config.enableDueDateWriteback)
                        .help("When enabled, changing a due date in Reminders will update the 📅 date in Obsidian")

                    Toggle("Sync start date changes back to Obsidian", isOn: $syncManager.config.enableStartDateWriteback)
                        .help("When enabled, changing a start date in Reminders will update the 🛫 date in Obsidian")

                    Toggle("Sync priority changes back to Obsidian", isOn: $syncManager.config.enablePriorityWriteback)
                        .help("When enabled, changing priority in Reminders will update the priority emoji (⏫/🔼/🔽) in Obsidian")

                    Toggle("Write new Reminders tasks to Obsidian inbox", isOn: $syncManager.config.enableNewTaskWriteback)
                        .help("When enabled, new tasks created in Reminders will be appended to an inbox file in your vault")

                    if syncManager.config.enableNewTaskWriteback {
                        HStack {
                            Text("Inbox file:")
                                .foregroundColor(.secondary)
                            TextField("Inbox.md", text: $syncManager.config.inboxFilePath)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 200)
                        }
                        .padding(.leading, 20)
                    }

                    if syncManager.config.enableCompletionWriteback || syncManager.config.enableDueDateWriteback || syncManager.config.enableStartDateWriteback || syncManager.config.enablePriorityWriteback || syncManager.config.enableNewTaskWriteback {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundColor(.orange)
                                .font(.caption)
                            Text("Writeback is active. Your Obsidian files will be modified. Backups are created automatically.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.leading, 20)
                    }
                } header: {
                    Text("Sync Behavior")
                }

                Section {
                    Toggle("Enable notifications", isOn: $syncManager.config.enableNotifications)
                        .help("Show macOS notifications for sync errors and first sync completion")
                } header: {
                    Text("Notifications")
                }

                Section {
                    Picker("Default Reminders list", selection: $syncManager.config.defaultList) {
                        ForEach(syncManager.availableLists, id: \.self) { list in
                            Text(list).tag(list)
                        }
                    }
                    .onAppear {
                        syncManager.refreshLists()
                    }

                    Button("Refresh Lists") {
                        syncManager.refreshLists()
                    }
                    .font(.caption)
                } header: {
                    Text("Default List")
                }

                Section {
                    Toggle("Hide dock icon", isOn: $syncManager.config.hideDockIcon)
                        .onChange(of: syncManager.config.hideDockIcon) { _ in
                            syncManager.updateDockIconVisibility()
                        }
                        .help("App will only appear in the menu bar")

                    Toggle("Force dark mode", isOn: $syncManager.config.forceDarkIcon)
                        .onChange(of: syncManager.config.forceDarkIcon) { _ in
                            syncManager.updateAppIcon()
                        }
                        .help("Forces the app into dark mode regardless of system setting")

                    Toggle("Global sync hotkey", isOn: $syncManager.config.globalHotKeyEnabled)
                        .onChange(of: syncManager.config.globalHotKeyEnabled) { _ in
                            syncManager.updateHotKey()
                        }
                        .help("Register a global keyboard shortcut to trigger sync from any app")

                    if syncManager.config.globalHotKeyEnabled {
                        HStack {
                            Text("Hotkey:")
                                .foregroundColor(.secondary)
                            Text(HotKeyService.describeHotKey(
                                keyCode: syncManager.config.globalHotKeyCode,
                                modifiers: syncManager.config.globalHotKeyModifiers
                            ))
                            .font(.system(.body, design: .monospaced))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color(NSColor.controlBackgroundColor))
                            .cornerRadius(4)
                        }
                        .padding(.leading, 20)
                    }
                } header: {
                    Text("Appearance & Shortcuts")
                }
            }
            .padding()
        }
    }
}

// MARK: - List Mappings

struct ListMappingsView: View {
    @EnvironmentObject var syncManager: SyncManager
    @State private var newTag = ""
    @State private var newList = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Map Obsidian tags to Reminders lists")
                .font(.headline)

            Text("Tasks with #tag will sync to the mapped Reminders list")
                .font(.caption)
                .foregroundColor(.secondary)

            List {
                ForEach(Array(syncManager.config.listMappings.enumerated()), id: \.element.id) { index, mapping in
                    HStack {
                        Text("#\(mapping.obsidianTag)")
                            .fontWeight(.medium)
                            .foregroundColor(.accentColor)

                        Image(systemName: "arrow.right")
                            .foregroundColor(.secondary)

                        Text(mapping.remindersList)

                        Spacer()

                        Button(action: {
                            syncManager.removeListMapping(at: index)
                        }) {
                            Image(systemName: "trash")
                                .foregroundColor(.red)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 4)
                }
            }
            .frame(minHeight: 150)

            Divider()

            HStack {
                TextField("Tag (e.g., work)", text: $newTag)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 150)

                Image(systemName: "arrow.right")
                    .foregroundColor(.secondary)

                Picker("List", selection: $newList) {
                    Text("Select list...").tag("")
                    ForEach(syncManager.availableLists, id: \.self) { list in
                        Text(list).tag(list)
                    }
                }
                .frame(width: 150)

                Button("Add") {
                    guard !newTag.isEmpty && !newList.isEmpty else { return }
                    syncManager.addListMapping(obsidianTag: newTag, remindersList: newList)
                    newTag = ""
                    newList = ""
                }
                .disabled(newTag.isEmpty || newList.isEmpty)
            }
        }
        .padding()
        .onAppear {
            syncManager.refreshLists()
        }
    }
}

// MARK: - Advanced Settings

struct AdvancedSettingsView: View {
    @EnvironmentObject var syncManager: SyncManager
    @State private var showResetConfirmation = false

    var body: some View {
        Form {
            Section {
                Picker("Task Source", selection: $syncManager.config.taskSourceType) {
                    ForEach(SyncConfiguration.TaskSourceType.allCases, id: \.self) { type in
                        Text(type.displayName).tag(type)
                    }
                }
                .onChange(of: syncManager.config.taskSourceType) { _ in
                    syncManager.updateSourceAndDestination()
                }

                Picker("Sync To", selection: $syncManager.config.taskDestinationType) {
                    ForEach(SyncConfiguration.TaskDestinationType.allCases, id: \.self) { type in
                        Text(type.displayName).tag(type)
                    }
                }
                .onChange(of: syncManager.config.taskDestinationType) { _ in
                    syncManager.updateSourceAndDestination()
                }

                if syncManager.config.taskDestinationType == .things3 {
                    HStack {
                        Text("Auth Token:")
                            .foregroundColor(.secondary)
                        SecureField("From Things > Settings > General", text: $syncManager.config.things3AuthToken)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 250)
                    }
                    .padding(.leading, 20)

                    Text("Required for updating tasks. Go to Things > Settings > General > Enable Things URLs to get your token.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.leading, 20)
                }

                if syncManager.config.taskSourceType == .taskNotes {
                    HStack {
                        Text("Integration:")
                            .foregroundColor(.secondary)
                        Picker("", selection: $syncManager.config.taskNotesIntegrationMode) {
                            Text("CLI (mtn)").tag("cli")
                            Text("Direct Files").tag("file")
                            Text("HTTP API").tag("http")
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 250)
                    }
                    .padding(.leading, 20)
                    .onChange(of: syncManager.config.taskNotesIntegrationMode) { _ in
                        syncManager.updateSourceAndDestination()
                    }

                    if syncManager.config.taskNotesIntegrationMode == "cli" {
                        Text("Uses mdbase-tasknotes CLI. Works without Obsidian. Install: npm install -g mdbase-tasknotes")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.leading, 20)
                    } else if syncManager.config.taskNotesIntegrationMode == "http" {
                        Text("Requires Obsidian to be open with the TaskNotes plugin running.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.leading, 20)

                        HStack {
                            Text("API Port:")
                                .foregroundColor(.secondary)
                            TextField("8080", text: Binding(
                                get: { String(syncManager.config.taskNotesApiPort) },
                                set: { value in
                                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                                    if trimmed.isEmpty {
                                        syncManager.config.taskNotesApiPort = 8080
                                        return
                                    }

                                    if let port = Int(trimmed), (1...65535).contains(port) {
                                        syncManager.config.taskNotesApiPort = port
                                    }
                                }
                            ))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 120)
                        }
                        .padding(.leading, 20)
                    }

                    HStack {
                        Text("Tasks Folder:")
                            .foregroundColor(.secondary)
                        TextField("tasks", text: $syncManager.config.taskNotesFolder)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 200)
                    }
                    .padding(.leading, 20)

                    Text("Relative path within your vault where TaskNotes stores task files. Leave empty for default (vault root).")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.leading, 20)
                }
            } header: {
                Text("Source & Destination")
            }

            Section {
                Toggle("Sync completed tasks", isOn: $syncManager.config.syncCompletedTasks)

                Toggle("Dry run mode", isOn: $syncManager.config.dryRunMode)
                    .help("Shows what would change without making any actual changes")

                if syncManager.config.dryRunMode {
                    HStack(spacing: 4) {
                        Image(systemName: "eye")
                            .foregroundColor(.yellow)
                            .font(.caption)
                        Text("Dry run is active. No changes will be made.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.leading, 20)
                }

                Text("\(syncManager.config.taskSourceType.displayName) is the source of truth. Changes are synced to \(syncManager.config.taskDestinationType.displayName).")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } header: {
                Text("Sync Options")
            }

            Section {
                LabeledContent {
                    TextField("e.g. Work, Personal", text: Binding(
                        get: { syncManager.config.includedFolders.joined(separator: ", ") },
                        set: { syncManager.config.includedFolders = $0.split(separator: ",").map { String($0.trimmingCharacters(in: .whitespaces)) } }
                    ))
                    .textFieldStyle(.roundedBorder)
                } label: {
                    Text("Only scan")
                }

                Text("Comma-separated. If set, ONLY these folders will be scanned (plus root .md files). Leave empty to scan the entire vault.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                LabeledContent {
                    TextField(".obsidian, .git, .trash", text: Binding(
                        get: { syncManager.config.excludedFolders.joined(separator: ", ") },
                        set: { syncManager.config.excludedFolders = $0.split(separator: ",").map { String($0.trimmingCharacters(in: .whitespaces)) } }
                    ))
                    .textFieldStyle(.roundedBorder)
                } label: {
                    Text("Exclude")
                }

                Text("Comma-separated. These folders are always skipped.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } header: {
                Text("Folder Filtering")
            }

            Section {
                Button("Reset Sync State") {
                    showResetConfirmation = true
                }
                .foregroundColor(.red)

                Text("This will clear all sync mappings. Use if sync is stuck or corrupted.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } header: {
                Text("Troubleshooting")
            }

            Section {
                Button("Open Backups Folder") {
                    NSWorkspace.shared.open(FileBackupService.shared.backupDirectoryURL)
                }

                Button("Open Audit Log") {
                    NSWorkspace.shared.open(AuditLog.shared.auditLogURL)
                }

                Text("Backups are created automatically before any Obsidian file modification.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } header: {
                Text("Recovery")
            }
        }
        .padding()
        .alert("Reset Sync State?", isPresented: $showResetConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Reset", role: .destructive) {
                syncManager.resetSyncState()
            }
        } message: {
            Text("This will clear all sync mappings. The next sync will treat all tasks as new.")
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(SyncManager.shared)
}
