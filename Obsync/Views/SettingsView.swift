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
                    Label("Mappings", systemImage: "arrow.triangle.swap")
                }
                .tag(1)

            if syncManager.config.taskSourceType == .taskNotes {
                TaskNotesSettingsView()
                    .tabItem {
                        Label("TaskNotes", systemImage: "doc.text")
                    }
                    .tag(3)
            }

            AdvancedSettingsView()
                .tabItem {
                    Label("Advanced", systemImage: "slider.horizontal.3")
                }
                .tag(2)
        }
        .frame(minWidth: 700, idealWidth: 800, minHeight: 600, idealHeight: 750)
    }
}

// MARK: - General Settings

struct GeneralSettingsView: View {
    @EnvironmentObject var syncManager: SyncManager
    @State private var showNewProfileAlert = false
    @State private var showRenameAlert = false
    @State private var showDeleteProfileConfirm = false
    @State private var profileNameField = ""

    var body: some View {
        ScrollView {
            Form {
                // Sync Profiles — independent source→destination pipelines. (multi-profile)
                Section {
                    Picker("Active profile", selection: Binding(
                        get: { syncManager.profileStore.activeProfileId },
                        set: { syncManager.switchProfile(to: $0) }
                    )) {
                        ForEach(syncManager.profileStore.profiles) { profile in
                            Text(profile.enabled ? profile.name : "\(profile.name) (paused)").tag(profile.id)
                        }
                    }

                    Toggle("Include this profile when syncing", isOn: Binding(
                        get: { syncManager.profileStore.activeProfile?.enabled ?? true },
                        set: { syncManager.setProfileEnabled(id: syncManager.profileStore.activeProfileId, enabled: $0) }
                    ))

                    HStack {
                        Button("New Profile…") { profileNameField = ""; showNewProfileAlert = true }
                        Button("Rename…") {
                            profileNameField = syncManager.profileStore.activeProfile?.name ?? ""
                            showRenameAlert = true
                        }
                        Spacer()
                        Button("Delete", role: .destructive) { showDeleteProfileConfirm = true }
                            .disabled((syncManager.profileStore.activeProfile?.isDefault ?? true)
                                      || syncManager.profileStore.profiles.count <= 1)
                    }

                    Text("Each profile is an independent source → destination pipeline with its own mappings, filters, tokens, and sync state. All enabled profiles sync together. Every setting below applies to the selected profile.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } header: {
                    Text("Sync Profiles")
                }

                // Source & Destination — primary choice, belongs in General
                Section {
                    Picker("Task Source", selection: $syncManager.config.taskSourceType) {
                        ForEach(SyncConfiguration.TaskSourceType.allCases, id: \.self) { type in
                            Text(type.displayName).tag(type)
                        }
                    }
                    .onChange(of: syncManager.config.taskSourceType) { _ in
                        syncManager.updateSourceAndDestination()
                    }

                    if syncManager.config.taskSourceType == .genericMarkdown {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Token dialect — configure how your tool marks dates and priority on a task line. Defaults match NotePlan. Leave a field blank to disable it.")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            HStack {
                                Text("File extensions:").foregroundColor(.secondary)
                                TextField("md, txt", text: Binding(
                                    get: { syncManager.config.genericMarkdown.fileExtensions.joined(separator: ", ") },
                                    set: { syncManager.config.genericMarkdown.fileExtensions = $0.split(separator: ",").map { String($0.trimmingCharacters(in: .whitespaces)) }.filter { !$0.isEmpty } }
                                ))
                                .textFieldStyle(.roundedBorder).frame(width: 160)
                            }
                            HStack {
                                Text("Due token:").foregroundColor(.secondary)
                                TextField(">", text: $syncManager.config.genericMarkdown.dueToken)
                                    .textFieldStyle(.roundedBorder).frame(width: 80)
                                Text("Start:").foregroundColor(.secondary)
                                TextField("(off)", text: $syncManager.config.genericMarkdown.startToken)
                                    .textFieldStyle(.roundedBorder).frame(width: 80)
                                Text("Done:").foregroundColor(.secondary)
                                TextField("@done", text: $syncManager.config.genericMarkdown.doneToken)
                                    .textFieldStyle(.roundedBorder).frame(width: 90)
                            }
                            HStack {
                                Text("Priority high/med/low:").foregroundColor(.secondary)
                                TextField("!!!", text: $syncManager.config.genericMarkdown.priorityHighToken)
                                    .textFieldStyle(.roundedBorder).frame(width: 60)
                                TextField("!!", text: $syncManager.config.genericMarkdown.priorityMediumToken)
                                    .textFieldStyle(.roundedBorder).frame(width: 60)
                                TextField("!", text: $syncManager.config.genericMarkdown.priorityLowToken)
                                    .textFieldStyle(.roundedBorder).frame(width: 60)
                            }
                            Text("Dates accept bare (`>2025-01-20`) and parenthesized (`@done(2025-01-20)`) forms. Tasks use `- [ ]` / `- [x]` checkboxes (also `*`/`+` bullets). Recurrence isn't parsed in this dialect.")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        .padding(.leading, 20)
                        .padding(.vertical, 4)
                    }

                    Picker("Sync To", selection: $syncManager.config.taskDestinationType) {
                        Label("Apple Reminders", systemImage: "checklist")
                            .tag(SyncConfiguration.TaskDestinationType.appleReminders)
                        Label("Things 3", image: "things")
                            .tag(SyncConfiguration.TaskDestinationType.things3)
                        Label("Todoist", image: "todoist")
                            .tag(SyncConfiguration.TaskDestinationType.todoist)
                        Label("TickTick", image: "ticktick")
                            .tag(SyncConfiguration.TaskDestinationType.tickTick)
                        Label("Asana", image: "asana")
                            .tag(SyncConfiguration.TaskDestinationType.asana)
                        Label("Linear", image: "linear")
                            .tag(SyncConfiguration.TaskDestinationType.linear)
                        Label("Calendar Feed", systemImage: "calendar")
                            .tag(SyncConfiguration.TaskDestinationType.calendarFeed)
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

                    if syncManager.config.taskDestinationType == .todoist {
                        HStack {
                            Text("API Token:")
                                .foregroundColor(.secondary)
                            SecureField("From Todoist Settings > Integrations", text: $syncManager.config.todoistApiToken)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 250)
                        }
                        .padding(.leading, 20)

                        Text("Get your token from Todoist > Settings > Integrations > Developer.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.leading, 20)
                    }

                    if syncManager.config.taskDestinationType == .tickTick {
                        if !TickTickDestination.isOAuthConfigured {
                            // OAuth credentials not yet registered
                            HStack {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.orange)
                                Text("TickTick integration coming soon")
                                    .foregroundColor(.secondary)
                            }
                            .padding(.leading, 20)

                            Text("TickTick OAuth registration is pending. This destination will be available in a future update.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .padding(.leading, 20)
                        } else if syncManager.config.tickTickAccessToken.isEmpty {
                            Button("Connect TickTick") {
                                syncManager.connectTickTick()
                            }
                            .padding(.leading, 20)

                            Text("Authorize Remindian to access your TickTick account via OAuth.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .padding(.leading, 20)
                        } else {
                            HStack {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                Text("Connected to TickTick")
                                    .foregroundColor(.secondary)
                                Spacer()
                                Button("Disconnect") {
                                    syncManager.config.tickTickAccessToken = ""
                                    syncManager.config.tickTickRefreshToken = ""
                                    syncManager.config.tickTickTokenExpiry = nil
                                    syncManager.updateSourceAndDestination()
                                }
                                .font(.caption)
                            }
                            .padding(.leading, 20)
                        }

                        Text("Note: TickTick's API does not support tags. Tags from Obsidian will not sync to TickTick.")
                            .font(.caption)
                            .foregroundColor(.orange)
                            .padding(.leading, 20)
                    }

                    if syncManager.config.taskDestinationType == .asana {
                        HStack {
                            Text("API Token:")
                                .foregroundColor(.secondary)
                            SecureField("Personal Access Token", text: $syncManager.config.asanaApiToken)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 250)
                        }
                        .padding(.leading, 20)

                        Text("Get your token from Asana > My Settings > Apps > Developer Apps > Personal Access Tokens.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.leading, 20)
                    }

                    if syncManager.config.taskDestinationType == .linear {
                        HStack {
                            Text("API Key:")
                                .foregroundColor(.secondary)
                            SecureField("Personal API Key", text: $syncManager.config.linearApiKey)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 250)
                        }
                        .padding(.leading, 20)

                        Text("Get your key from Linear > Settings > API > Personal API Keys.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.leading, 20)

                        Text("Tasks map to Linear issues. Obsidian lists map to Linear teams.")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .padding(.leading, 20)
                    }

                    if syncManager.config.taskDestinationType == .calendarFeed {
                        HStack {
                            Text("Output path:")
                                .foregroundColor(.secondary)
                            TextField("~/Documents/remindian-tasks.ics", text: $syncManager.config.calendarFeedOutputPath)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 250)
                        }
                        .padding(.leading, 20)

                        HStack {
                            Text("Calendar name:")
                                .foregroundColor(.secondary)
                            TextField("Remindian Tasks", text: $syncManager.config.calendarFeedName)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 200)
                        }
                        .padding(.leading, 20)

                        Text("Generates a subscribable .ics file with your tasks as VTODO entries. Subscribe to it from Apple Calendar, Google Calendar, or any CalDAV client.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.leading, 20)
                    }
                } header: {
                    Text("Source & Destination")
                }

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

                // Obsidian → Reminders settings (#24 — separate sync directions)
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

                    if syncManager.config.taskDestinationType == .appleReminders {
                        Toggle("Add an alarm to reminders", isOn: $syncManager.config.addReminderAlarm)
                            .help("Apple Reminders only notify you if they have an alarm. When on, each synced reminder with a due date gets one.")

                        if syncManager.config.addReminderAlarm {
                            HStack {
                                Text("Alarm time for all-day tasks:")
                                    .foregroundColor(.secondary)
                                Picker("", selection: $syncManager.config.reminderAlarmHour) {
                                    ForEach(0..<24, id: \.self) { hour in
                                        Text(String(format: "%02d:00", hour)).tag(hour)
                                    }
                                }
                                .labelsHidden()
                                .frame(width: 90)
                            }
                            .padding(.leading, 20)

                            Text("Tasks with a specific time alarm at that time; date-only tasks alarm at the time above. Existing reminders' alarms aren't changed.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .padding(.leading, 20)
                        }
                    }
                } header: {
                    Label("Obsidian \u{2192} \(syncManager.config.taskDestinationType.displayName)", systemImage: "arrow.right")
                }

                // Destination → Obsidian settings (#24 — separate sync directions)
                Section {
                    Toggle("Sync completions back", isOn: $syncManager.config.enableCompletionWriteback)
                        .help("Marking a task complete in \(syncManager.config.taskDestinationType.displayName) will update the checkbox and add a completion date in Obsidian")

                    Toggle("Sync due date changes back", isOn: $syncManager.config.enableDueDateWriteback)
                        .help("Changing a due date in \(syncManager.config.taskDestinationType.displayName) will update the \u{1F4C5} date in Obsidian")

                    Toggle("Sync start date changes back", isOn: $syncManager.config.enableStartDateWriteback)
                        .help("Changing a start date in \(syncManager.config.taskDestinationType.displayName) will update the \u{1F6EB} date in Obsidian")

                    Toggle("Sync priority changes back", isOn: $syncManager.config.enablePriorityWriteback)
                        .help("Changing priority in \(syncManager.config.taskDestinationType.displayName) will update the priority emoji in Obsidian")

                    Toggle("Sync tag changes back", isOn: $syncManager.config.enableTagWriteback)
                        .help("Tag changes in \(syncManager.config.taskDestinationType.displayName) will update #tags in Obsidian")

                    Toggle("Write new \(syncManager.config.taskDestinationType.displayName) tasks to Obsidian", isOn: $syncManager.config.enableNewTaskWriteback)
                        .help("New tasks created in \(syncManager.config.taskDestinationType.displayName) will be appended to an inbox file in your vault")

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

                    if syncManager.config.enableCompletionWriteback || syncManager.config.enableDueDateWriteback || syncManager.config.enableStartDateWriteback || syncManager.config.enablePriorityWriteback || syncManager.config.enableTagWriteback || syncManager.config.enableNewTaskWriteback {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundColor(.orange)
                                .font(.caption)
                            Text("Writeback is active. Your Obsidian files will be modified. Backups are created automatically.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                } header: {
                    Label("\(syncManager.config.taskDestinationType.displayName) \u{2192} Obsidian (Writeback)", systemImage: "arrow.left")
                }

                Section {
                    Toggle("Enable notifications", isOn: $syncManager.config.enableNotifications)
                        .help("Show macOS notifications for sync errors and first sync completion")
                } header: {
                    Text("Notifications")
                }

                Section {
                    Picker("Default list", selection: $syncManager.config.defaultList) {
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

                    if syncManager.config.taskSourceType == .taskNotes && syncManager.config.taskNotesListField != "tags" {
                        Text("Tasks with a \(syncManager.config.taskNotesListField) field will go to that list instead. This is the fallback for tasks without one.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        Text("Tasks with a matching tag mapping go to that list. This is the fallback for untagged tasks.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } header: {
                    Text("Default List")
                }

                Section {
                    Toggle("Launch at login", isOn: $syncManager.config.launchAtLogin)
                        .onChange(of: syncManager.config.launchAtLogin) { newValue in
                            syncManager.updateLaunchAtLogin(newValue)
                        }
                        .help("Automatically start Remindian when you log in")

                    Toggle("Hide dock icon", isOn: $syncManager.config.hideDockIcon)
                        .onChange(of: syncManager.config.hideDockIcon) { _ in
                            syncManager.updateDockIconVisibility()
                        }
                        .help("App will only appear in the menu bar")

                    Toggle("Show task count on menu bar icon", isOn: $syncManager.config.showMenuBarTaskCount)
                        .help("Shows the number of tasks due today or overdue next to the menu bar icon")

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
            .formStyle(.grouped)
        }
        .alert("New Profile", isPresented: $showNewProfileAlert) {
            TextField("Profile name", text: $profileNameField)
            Button("Create") {
                let name = profileNameField.trimmingCharacters(in: .whitespaces)
                syncManager.addProfile(name: name.isEmpty ? "New Profile" : name)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Creates a new sync pipeline, copied from the current profile as a starting point. Adjust its source, destination, vault, and mappings below.")
        }
        .alert("Rename Profile", isPresented: $showRenameAlert) {
            TextField("Profile name", text: $profileNameField)
            Button("Save") {
                let name = profileNameField.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty {
                    syncManager.renameProfile(id: syncManager.profileStore.activeProfileId, to: name)
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Delete this profile?", isPresented: $showDeleteProfileConfirm) {
            Button("Delete", role: .destructive) {
                syncManager.deleteProfile(id: syncManager.profileStore.activeProfileId)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes the profile and its sync-state mappings. Tasks already synced to your destination are not deleted.")
        }
    }
}

// MARK: - List Mappings

struct ListMappingsView: View {
    @EnvironmentObject var syncManager: SyncManager
    @State private var newTag = ""
    @State private var newList = ""
    @State private var newFilePath = ""
    @State private var newFileList = ""
    @State private var newFolderPath = ""
    @State private var newFolderList = ""

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 16) {
            // MARK: - Tag Mappings
            Text("Tag \u{2192} List Mappings")
                .font(.headline)

            Text("Tasks with #tag or +tag will sync to the mapped list")
                .font(.caption)
                .foregroundColor(.secondary)

            List {
                // Iterate the array directly (not an enumerated snapshot) so
                // SwiftUI tracks the underlying @Published array and redraws
                // when items are removed by id. (#62.3)
                ForEach(syncManager.config.listMappings) { mapping in
                    HStack {
                        Text(mapping.obsidianTag.hasPrefix("+") ? mapping.obsidianTag : "#\(mapping.obsidianTag)")
                            .fontWeight(.medium)
                            .foregroundColor(.accentColor)

                        Image(systemName: "arrow.right")
                            .foregroundColor(.secondary)

                        Text(mapping.remindersList)

                        Spacer()

                        Button(action: {
                            syncManager.removeListMapping(id: mapping.id)
                        }) {
                            Image(systemName: "trash")
                                .foregroundColor(.red)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 4)
                }
            }
            .frame(minHeight: 100)

            HStack {
                TextField("Tag (e.g., work or +project)", text: $newTag)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 120, maxWidth: 250)

                Image(systemName: "arrow.right")
                    .foregroundColor(.secondary)

                Picker("List", selection: $newList) {
                    Text("Select list...").tag("")
                    ForEach(syncManager.availableLists, id: \.self) { list in
                        Text(list).tag(list)
                    }
                }
                .frame(minWidth: 120, maxWidth: 200)

                Button("Add") {
                    guard !newTag.isEmpty && !newList.isEmpty else { return }
                    syncManager.addListMapping(obsidianTag: newTag, remindersList: newList)
                    newTag = ""
                    newList = ""
                }
                .disabled(newTag.isEmpty || newList.isEmpty)
            }

            Divider()

            // MARK: - File Path Mappings (#37)
            Text("File \u{2192} List Mappings")
                .font(.headline)

            Text("All tasks in the specified file will sync to the mapped list, regardless of their tags")
                .font(.caption)
                .foregroundColor(.secondary)

            List {
                // See note on listMappings ForEach above (#62.3).
                ForEach(syncManager.config.filePathMappings) { mapping in
                    HStack {
                        Image(systemName: "doc.text")
                            .foregroundColor(.secondary)

                        Text(mapping.filePath)
                            .fontWeight(.medium)
                            .foregroundColor(.accentColor)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Image(systemName: "arrow.right")
                            .foregroundColor(.secondary)

                        Text(mapping.remindersList)

                        Spacer()

                        Button(action: {
                            syncManager.removeFileMapping(id: mapping.id)
                        }) {
                            Image(systemName: "trash")
                                .foregroundColor(.red)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 4)
                }
            }
            .frame(minHeight: 80)

            HStack {
                TextField("File path (e.g., Projects/Work.md)", text: $newFilePath)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 150, maxWidth: 300)

                Image(systemName: "arrow.right")
                    .foregroundColor(.secondary)

                Picker("List", selection: $newFileList) {
                    Text("Select list...").tag("")
                    ForEach(syncManager.availableLists, id: \.self) { list in
                        Text(list).tag(list)
                    }
                }
                .frame(minWidth: 120, maxWidth: 200)

                Button("Add") {
                    guard !newFilePath.isEmpty && !newFileList.isEmpty else { return }
                    syncManager.addFileMapping(filePath: newFilePath, remindersList: newFileList)
                    newFilePath = ""
                    newFileList = ""
                }
                .disabled(newFilePath.isEmpty || newFileList.isEmpty)
            }

            Text("Use the relative path from your vault root (e.g., Projects/Work.md)")
                .font(.caption2)
                .foregroundColor(.secondary)

            Divider()

            // MARK: - Folder Path Mappings (#40)
            Text("Folder \u{2192} List Mappings")
                .font(.headline)

            Text("All tasks in any file within the specified folder (and subfolders) will sync to the mapped list")
                .font(.caption)
                .foregroundColor(.secondary)

            List {
                // See note on listMappings ForEach above (#62.3).
                ForEach(syncManager.config.folderPathMappings) { mapping in
                    HStack {
                        Image(systemName: "folder.fill")
                            .foregroundColor(.secondary)

                        Text(mapping.folderPath)
                            .fontWeight(.medium)
                            .foregroundColor(.accentColor)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Image(systemName: "arrow.right")
                            .foregroundColor(.secondary)

                        Text(mapping.remindersList)

                        Spacer()

                        Button(action: {
                            syncManager.removeFolderMapping(id: mapping.id)
                        }) {
                            Image(systemName: "trash")
                                .foregroundColor(.red)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 4)
                }
            }
            .frame(minHeight: 80)

            HStack {
                TextField("Folder path (e.g., Projects/Work)", text: $newFolderPath)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 150, maxWidth: 300)

                Image(systemName: "arrow.right")
                    .foregroundColor(.secondary)

                Picker("List", selection: $newFolderList) {
                    Text("Select list...").tag("")
                    ForEach(syncManager.availableLists, id: \.self) { list in
                        Text(list).tag(list)
                    }
                }
                .frame(minWidth: 120, maxWidth: 200)

                Button("Add") {
                    guard !newFolderPath.isEmpty && !newFolderList.isEmpty else { return }
                    syncManager.addFolderMapping(folderPath: newFolderPath, remindersList: newFolderList)
                    newFolderPath = ""
                    newFolderList = ""
                }
                .disabled(newFolderPath.isEmpty || newFolderList.isEmpty)
            }

            Text("Use the relative folder path from your vault root. More specific folders take priority over broader ones.")
                .font(.caption2)
                .foregroundColor(.secondary)

            // Mapping priority explanation
            GroupBox {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Mapping Priority (highest to lowest):")
                        .font(.caption)
                        .fontWeight(.semibold)
                    Text("1. Explicit tag mapping (#tag \u{2192} List)")
                        .font(.caption2)
                    Text("2. File path mapping (file.md \u{2192} List)")
                        .font(.caption2)
                    Text("3. Folder path mapping (folder/ \u{2192} List)")
                        .font(.caption2)
                    Text("4. Auto-capitalize tag name")
                        .font(.caption2)
                    Text("5. Default list")
                        .font(.caption2)
                }
                .foregroundColor(.secondary)
            }
        }
        .padding()
        } // ScrollView
        .onAppear {
            syncManager.refreshLists()
        }
    }
}

// MARK: - TaskNotes Settings (#24 — separate tab with individual rows and wider fields)

struct TaskNotesSettingsView: View {
    @EnvironmentObject var syncManager: SyncManager

    var body: some View {
        ScrollView {
            Form {
                Section {
                    HStack {
                        Text("Integration:")
                            .foregroundColor(.secondary)
                        Picker("", selection: $syncManager.config.taskNotesIntegrationMode) {
                            Text("CLI (mtn)").tag("cli")
                            Text("Direct Files").tag("file")
                            Text("HTTP API").tag("http")
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 280)
                    }
                    .onChange(of: syncManager.config.taskNotesIntegrationMode) { _ in
                        syncManager.updateSourceAndDestination()
                    }

                    if syncManager.config.taskNotesIntegrationMode == "cli" {
                        Text("Uses mdbase-tasknotes CLI. Works without Obsidian. Install: npm install -g mdbase-tasknotes")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        HStack {
                            Text("mtn path:")
                                .foregroundColor(.secondary)
                            TextField("/opt/homebrew/bin/mtn", text: $syncManager.config.taskNotesMtnPath)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: .infinity)
                            Button("Browse...") {
                                syncManager.selectMtnBinary()
                            }
                        }

                        if syncManager.config.taskNotesMtnPath.isEmpty {
                            Text("Select the mtn binary to grant sandbox access. Run 'which mtn' in Terminal to find its location.")
                                .font(.caption)
                                .foregroundColor(.orange)
                        } else {
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                    .font(.caption)
                                Text("mtn configured: \(syncManager.config.taskNotesMtnPath)")
                            }
                            .font(.caption)
                            .foregroundColor(.secondary)
                        }
                    } else if syncManager.config.taskNotesIntegrationMode == "http" {
                        Text("Uses the TaskNotes plugin HTTP API. Requires Obsidian to be open.")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        HStack {
                            Text("API URL:")
                                .foregroundColor(.secondary)
                            TextField("http://localhost:8080", text: $syncManager.config.taskNotesApiUrl)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: .infinity)
                        }
                        .onChange(of: syncManager.config.taskNotesApiUrl) { _ in
                            syncManager.updateSourceAndDestination()
                        }
                    }

                    HStack {
                        Text("Tasks Folder:")
                            .foregroundColor(.secondary)
                        TextField("tasks", text: $syncManager.config.taskNotesFolder)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: .infinity)
                    }

                    Text("Relative path within your vault where TaskNotes stores task files.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } header: {
                    Text("Integration")
                }

                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Completed statuses")
                            .foregroundColor(.secondary)
                            .font(.subheadline)
                        TextField("done, completed, cancelled, archived, shipped", text: Binding(
                            get: { syncManager.config.taskNotesCompletedStatuses.joined(separator: ", ") },
                            set: { syncManager.config.taskNotesCompletedStatuses = $0.split(separator: ",").map { String($0.trimmingCharacters(in: .whitespaces)) }.filter { !$0.isEmpty } }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: .infinity)
                        Text("Comma-separated list of status values that mean \"completed\".")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    HStack(spacing: 20) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Open status")
                                .foregroundColor(.secondary)
                                .font(.subheadline)
                            TextField("open", text: $syncManager.config.taskNotesOpenStatus)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 150)
                            Text("Written when marking incomplete")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Done status")
                                .foregroundColor(.secondary)
                                .font(.subheadline)
                            TextField("done", text: $syncManager.config.taskNotesDoneStatus)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 150)
                            Text("Written when marking complete")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                } header: {
                    Text("Status Mapping")
                }

                Section {
                    Text("Map your YAML frontmatter field names to Remindian properties. If your TaskNotes uses custom field names (e.g., \"deadline\" instead of \"due\"), configure them here.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    VStack(alignment: .leading, spacing: 10) {
                        FieldMappingRow(label: "Title", binding: $syncManager.config.taskNotesFieldMapping.title, placeholder: "title")
                        Divider()
                        FieldMappingRow(label: "Status", binding: $syncManager.config.taskNotesFieldMapping.status, placeholder: "status")
                        Divider()
                        FieldMappingRow(label: "Priority", binding: $syncManager.config.taskNotesFieldMapping.priority, placeholder: "priority")
                        Divider()
                        FieldMappingRow(label: "Due Date", binding: $syncManager.config.taskNotesFieldMapping.due, placeholder: "due")
                        Divider()
                        FieldMappingRow(label: "Start Date", binding: $syncManager.config.taskNotesFieldMapping.scheduled, placeholder: "scheduled")
                        Divider()
                        FieldMappingRow(label: "Completed", binding: $syncManager.config.taskNotesFieldMapping.completedDate, placeholder: "completedDate")
                        Divider()
                        FieldMappingRow(label: "Tags", binding: $syncManager.config.taskNotesFieldMapping.tags, placeholder: "tags")
                        Divider()
                        FieldMappingRow(label: "Project", binding: $syncManager.config.taskNotesFieldMapping.project, placeholder: "project")
                        Divider()
                        FieldMappingRow(label: "Context", binding: $syncManager.config.taskNotesFieldMapping.context, placeholder: "context")
                    }
                } header: {
                    Text("Field Mapping")
                }

                Section {
                    HStack {
                        Text("Reminders list from:")
                            .foregroundColor(.secondary)
                        Picker("", selection: $syncManager.config.taskNotesListField) {
                            Text("Tags").tag("tags")
                            Text("Project").tag("project")
                            Text("Context").tag("context")
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 250)
                    }

                    Text("Which TaskNotes field determines the Reminders list/folder. Supports wikilinks (e.g., [[My Project]] \u{2192} My Project). Tasks without a value fall back to the Default List in General.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } header: {
                    Text("List/Folder Source")
                }
            }
            .formStyle(.grouped)
        }
    }
}

/// Individual field mapping row — each field on its own line with wider text input (#24)
struct FieldMappingRow: View {
    let label: String
    @Binding var binding: String
    let placeholder: String

    var body: some View {
        HStack {
            Text(label)
                .foregroundColor(.secondary)
                .frame(width: 90, alignment: .trailing)
            TextField(placeholder, text: $binding)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Advanced Settings

struct AdvancedSettingsView: View {
    @EnvironmentObject var syncManager: SyncManager
    @State private var showResetConfirmation = false
    @State private var isCheckingDuplicates = false
    @State private var duplicateCount: Int?
    @State private var showDuplicateConfirm = false

    var body: some View {
        ScrollView {
        Form {
            Section {
                Toggle("Sync completed tasks", isOn: $syncManager.config.syncCompletedTasks)

                if syncManager.config.syncCompletedTasks {
                    HStack {
                        Text("Skip completed tasks older than:")
                            .foregroundColor(.secondary)
                        Picker("", selection: $syncManager.config.maxCompletedTaskAgeDays) {
                            Text("No limit").tag(0)
                            Text("7 days").tag(7)
                            Text("30 days").tag(30)
                            Text("90 days").tag(90)
                            Text("180 days").tag(180)
                            Text("1 year").tag(365)
                        }
                        .frame(width: 120)
                    }
                    .padding(.leading, 20)
                }

                Toggle("Add task link to Reminders", isOn: $syncManager.config.addTaskLinkToReminders)
                    .help("Adds an obsidian:// URL to the reminder's native URL field — Apple Reminders shows it as a clickable Obsidian icon.")

                // Secondary toggle, indented under the main one and only
                // surfaced when the parent is enabled. Default off since v5.10
                // (#69) — Apple Reminders renders the URL field cleanly so
                // the notes-side copy was just visual clutter. Available for
                // older clients that don't display URL fields.
                if syncManager.config.addTaskLinkToReminders {
                    Toggle("Also append URL to notes (legacy clients)", isOn: $syncManager.config.appendTaskLinkToNotes)
                        .help("Duplicates the obsidian:// URL into the reminder's notes body. Off by default — only useful if you use a client that doesn't show the URL field.")
                        .padding(.leading, 20)
                }

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

                if syncManager.config.taskSourceType == .obsidianTasks {
                    LabeledContent {
                        TextField("e.g. #task", text: $syncManager.config.globalFilter)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 200)
                    } label: {
                        Text("Global filter")
                    }

                    Text("Only sync tasks whose line contains this text. Matches the Obsidian Tasks plugin global filter setting. Leave empty to sync all tasks.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Toggle("Parse dataview inline fields", isOn: $syncManager.config.enableDataviewFormat)
                        .help("Also read [key::value] and (key::value) metadata from task lines")

                    if syncManager.config.enableDataviewFormat {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Recognized fields: due, start, scheduled, completed, priority, tags, project, list")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("Example: - [ ] Buy milk [due::2025-01-15] [priority::high] [project::Shopping]")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .italic()
                            Text("Emoji-based metadata takes precedence. Dataview fields fill in any gaps.")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        .padding(.leading, 20)
                    }

                    // Custom status markers (#63). Lets users opt into the
                    // Task-Board plugin's extended `[<]` / `[/]` / `[?]` /
                    // `[-]` markers. Default config preserves v5.8.x behavior
                    // — `[ ]` open and `[x]`/`[X]` completed — so this is
                    // purely additive.
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Custom status markers")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Text("Single characters inside `[ ]` that classify a task. Add markers from plugins like Task-Board. The standard `[ ]` open / `[x]` `[X]` completed are always recognized.")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        LabeledContent {
                            TextField(" , /, ?, <", text: Binding(
                                get: { syncManager.config.obsidianTasksOpenMarkers.joined(separator: ", ") },
                                set: { newValue in
                                    let parsed = newValue
                                        .split(separator: ",", omittingEmptySubsequences: false)
                                        .map { String($0).trimmingCharacters(in: .whitespaces) }
                                        .filter { $0.count == 1 }
                                    // Always ensure " " is included so users
                                    // can't accidentally lock themselves out
                                    // of the default open state.
                                    var withDefault = parsed
                                    if !withDefault.contains(" ") { withDefault.insert(" ", at: 0) }
                                    syncManager.config.obsidianTasksOpenMarkers = withDefault
                                }
                            ))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 250)
                        } label: {
                            Text("Open markers")
                        }

                        LabeledContent {
                            TextField("x, X, -", text: Binding(
                                get: { syncManager.config.obsidianTasksCompletedMarkers.joined(separator: ", ") },
                                set: { newValue in
                                    let parsed = newValue
                                        .split(separator: ",", omittingEmptySubsequences: false)
                                        .map { String($0).trimmingCharacters(in: .whitespaces) }
                                        .filter { $0.count == 1 }
                                    // Always ensure "x" is included — same
                                    // safety as above so the canonical
                                    // completion marker can't be removed.
                                    var withDefault = parsed
                                    if !withDefault.contains("x") { withDefault.insert("x", at: 0) }
                                    syncManager.config.obsidianTasksCompletedMarkers = withDefault
                                }
                            ))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 250)
                        } label: {
                            Text("Completed markers")
                        }

                        // Ignored markers (#70). No safety default — empty
                        // is the legitimate "don't ignore anything" state.
                        LabeledContent {
                            TextField("i, _", text: Binding(
                                get: { syncManager.config.obsidianTasksIgnoredMarkers.joined(separator: ", ") },
                                set: { newValue in
                                    syncManager.config.obsidianTasksIgnoredMarkers = newValue
                                        .split(separator: ",", omittingEmptySubsequences: false)
                                        .map { String($0).trimmingCharacters(in: .whitespaces) }
                                        .filter { $0.count == 1 }
                                }
                            ))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 250)
                        } label: {
                            Text("Ignored markers")
                        }

                        Text("Comma-separated single characters. Open and completed markers classify checkbox state; ignored markers tell Remindian to skip the line entirely (useful for status markers like `[i]` that aren't real tasks).")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
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

                Text("Comma-separated. If set, ONLY these folders will be scanned. Leave empty to scan the entire vault.")
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
            } header: {
                Text("Folder Filtering")
            }

            Section {
                LabeledContent {
                    TextField("e.g. Work, Personal", text: Binding(
                        get: { syncManager.config.syncedRemindersLists.joined(separator: ", ") },
                        set: { syncManager.config.syncedRemindersLists = $0.split(separator: ",").map { String($0.trimmingCharacters(in: .whitespaces)) }.filter { !$0.isEmpty } }
                    ))
                    .textFieldStyle(.roundedBorder)
                } label: {
                    Text("Only sync lists")
                }

                LabeledContent {
                    TextField("e.g. Groceries, Shared", text: Binding(
                        get: { syncManager.config.excludedRemindersLists.joined(separator: ", ") },
                        set: { syncManager.config.excludedRemindersLists = $0.split(separator: ",").map { String($0.trimmingCharacters(in: .whitespaces)) }.filter { !$0.isEmpty } }
                    ))
                    .textFieldStyle(.roundedBorder)
                } label: {
                    Text("Exclude lists")
                }
                LabeledContent {
                    TextField("e.g. Routine, SomeDay", text: Binding(
                        get: { syncManager.config.excludedTags.joined(separator: ", ") },
                        set: { syncManager.config.excludedTags = $0.split(separator: ",").map { String($0.trimmingCharacters(in: .whitespaces)) }.filter { !$0.isEmpty } }
                    ))
                    .textFieldStyle(.roundedBorder)
                } label: {
                    Text("Exclude tags")
                }

                Text("Tasks with any of these tags will be skipped during sync. Enter tag names without the # prefix, separated by commas.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } header: {
                Text("\(syncManager.config.taskDestinationType.displayName) List Filtering")
            }

            Section {
                Picker("Store sync state in", selection: $syncManager.config.syncStateLocation) {
                    ForEach(SyncConfiguration.SyncStateLocation.allCases, id: \.self) { loc in
                        Text(loc.displayName).tag(loc)
                    }
                }

                if syncManager.config.syncStateLocation == .vault {
                    Text("The mapping table is stored at `.remindian/sync_state.json` inside your vault. If you already sync your vault across Macs (Obsidian Sync, iCloud Drive, Dropbox, git…), each Mac reuses the same reminders instead of creating duplicates. Existing mappings on this Mac are copied into the vault the first time. For best results, avoid syncing on two Macs at the very same moment — Remindian reloads the shared state at the start of every sync.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text("The mapping table is stored in Application Support on this Mac only. Choose “Inside vault” to share mappings across devices via your existing vault sync.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } header: {
                Text("Sync State Storage")
            }

            Section {
                Button("Reset Sync State") {
                    showResetConfirmation = true
                }
                .foregroundColor(.red)

                Text("Clears all sync mappings, history, and logs. The next sync will treat all tasks as new.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                if syncManager.config.taskDestinationType == .appleReminders {
                    Divider()
                    HStack {
                        Button(isCheckingDuplicates ? "Checking…" : "Remove Duplicate Reminders…") {
                            Task {
                                isCheckingDuplicates = true
                                duplicateCount = await syncManager.previewDuplicateReminders()
                                isCheckingDuplicates = false
                                showDuplicateConfirm = true
                            }
                        }
                        .disabled(isCheckingDuplicates)
                        if isCheckingDuplicates { ProgressView().scaleEffect(0.6) }
                    }
                    Text("Finds reminders that are exact duplicates (same title, due date, list) — left over from older buggy versions — and removes all but one. Reminders synced from Obsidian (with the obsidian:// link) are kept.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } header: {
                Text("Troubleshooting")
            }

            Section {
                Button("Open Backups Folder") {
                    if let url = FileBackupService.shared.backupDirectoryURL {
                        // Ensure directory exists before trying to open it (may not exist on first launch)
                        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(url)
                    }
                }

                Button("Open Audit Log") {
                    if let url = AuditLog.shared.auditLogURL {
                        if !FileManager.default.fileExists(atPath: url.path) {
                            // Create empty file so Finder has something to open
                            FileManager.default.createFile(atPath: url.path, contents: nil)
                        }
                        NSWorkspace.shared.open(url)
                    }
                }

                Text("Backups are created automatically before any Obsidian file modification.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } header: {
                Text("Recovery")
            }
        }
        .formStyle(.grouped)
        }
        .alert("Reset Sync State?", isPresented: $showResetConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Reset", role: .destructive) {
                syncManager.resetSyncState()
            }
        } message: {
            Text("This will clear all sync mappings, history, and logs. The next sync will treat all tasks as new and re-create them in Reminders.")
        }
        .alert("Remove duplicate reminders?", isPresented: $showDuplicateConfirm) {
            if (duplicateCount ?? 0) > 0 {
                Button("Cancel", role: .cancel) { }
                Button("Remove \(duplicateCount ?? 0)", role: .destructive) {
                    Task { await syncManager.removeDuplicateReminders() }
                }
            } else {
                Button("OK", role: .cancel) { }
            }
        } message: {
            if let n = duplicateCount, n > 0 {
                Text("Found \(n) duplicate reminder\(n == 1 ? "" : "s") (same title, due date and list). Remove all but one of each? Reminders synced from Obsidian are kept. This can't be undone — but Obsidian stays your source of truth, so the next sync re-creates anything still in your vault.")
            } else {
                Text("No duplicate reminders found 🎉")
            }
        }
    }
}

// MARK: - Liquid Glass (macOS Tahoe)

/// Conditionally applies Liquid Glass effect on macOS 26+ (Tahoe).
/// Falls back to no-op on older macOS versions.
struct LiquidGlassModifier: ViewModifier {
    var cornerRadius: CGFloat = 12

    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius))
        } else {
            content
        }
    }
}

struct LiquidGlassClearModifier: ViewModifier {
    var cornerRadius: CGFloat = 12

    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.glassEffect(.clear, in: RoundedRectangle(cornerRadius: cornerRadius))
        } else {
            content
        }
    }
}

extension View {
    /// Apply Liquid Glass with `.regular` style (opaque-ish, for navigation/chrome).
    func liquidGlass(cornerRadius: CGFloat = 12) -> some View {
        modifier(LiquidGlassModifier(cornerRadius: cornerRadius))
    }

    /// Apply Liquid Glass with `.clear` style (transparent, for media-rich backgrounds).
    func liquidGlassClear(cornerRadius: CGFloat = 12) -> some View {
        modifier(LiquidGlassClearModifier(cornerRadius: cornerRadius))
    }
}

#Preview {
    SettingsView()
        .environmentObject(SyncManager.shared)
}
