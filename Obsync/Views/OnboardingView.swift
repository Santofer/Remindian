import SwiftUI

/// Onboarding wizard shown on first launch to guide users through setup.
struct OnboardingView: View {
    @EnvironmentObject var syncManager: SyncManager
    @Binding var isPresented: Bool
    @State private var currentStep = 0
    @State private var isRequestingAccess = false
    @State private var isSyncing = false

    @State private var newMappingTag = ""
    @State private var newMappingList = ""

    private let totalSteps = 5

    var body: some View {
        VStack(spacing: 0) {
            // Progress indicator
            HStack(spacing: 8) {
                ForEach(0..<totalSteps, id: \.self) { step in
                    Circle()
                        .fill(step <= currentStep ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 8, height: 8)
                }
            }
            .padding(.top, 20)

            // Content area
            Group {
                switch currentStep {
                case 0: welcomeStep
                case 1: vaultStep
                case 2: remindersStep
                case 3: configureStep
                case 4: finishStep
                default: EmptyView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Navigation buttons
            HStack {
                if currentStep > 0 {
                    Button("Back") {
                        withAnimation { currentStep -= 1 }
                    }
                }

                Spacer()

                if currentStep < totalSteps - 1 {
                    Button("Next") {
                        withAnimation { currentStep += 1 }
                    }
                    .keyboardShortcut(.return, modifiers: [])
                    .disabled(!canAdvance)
                } else {
                    Button("Get Started") {
                        completeOnboarding()
                    }
                    .keyboardShortcut(.return, modifiers: [])
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(20)
        }
        .frame(width: 500, height: 400)
    }

    // MARK: - Steps

    private var welcomeStep: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 60))
                .foregroundColor(.accentColor)

            Text("Welcome to Remindian")
                .font(.title)
                .fontWeight(.bold)

            Text("Sync your Obsidian Tasks with Apple Reminders.\nLet's get you set up in a few quick steps.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .padding(.horizontal, 40)

            Spacer()
        }
    }

    private var vaultStep: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "folder.fill")
                .font(.system(size: 48))
                .foregroundColor(.accentColor)

            Text("Select Your Vault")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Choose the Obsidian vault folder that contains your tasks.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .padding(.horizontal, 40)

            if !syncManager.config.vaultPath.isEmpty {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text(syncManager.config.vaultPath)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                .padding(.horizontal, 40)
            }

            Button("Browse...") {
                syncManager.selectVaultPath()
            }
            .buttonStyle(.borderedProminent)

            Spacer()
        }
    }

    private var remindersStep: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "checklist")
                .font(.system(size: 48))
                .foregroundColor(.accentColor)

            Text("Reminders Access")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Remindian needs permission to read and write your Apple Reminders.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .padding(.horizontal, 40)

            if syncManager.hasRemindersAccess {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("Access granted")
                }
            } else {
                Button(isRequestingAccess ? "Requesting..." : "Grant Access") {
                    isRequestingAccess = true
                    Task {
                        await syncManager.requestRemindersAccess()
                        isRequestingAccess = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isRequestingAccess)
            }

            Spacer()
        }
    }

    private var configureStep: some View {
        ScrollView {
            VStack(spacing: 16) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 48))
                    .foregroundColor(.accentColor)
                    .padding(.top, 10)

                Text("Configure Sync")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("Optional — you can always change these in Settings.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                // Folder filtering
                GroupBox("Folder Filtering") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Only scan these folders (whitelist)")
                            .font(.caption).fontWeight(.medium)
                        TextField("e.g. Work, Personal", text: Binding(
                            get: { syncManager.config.includedFolders.joined(separator: ", ") },
                            set: { syncManager.config.includedFolders = $0.split(separator: ",").map { String($0.trimmingCharacters(in: .whitespaces)) } }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))

                        Text("Leave empty to scan the entire vault. Root .md files (like Inbox.md) are always included.")
                            .font(.caption2).foregroundColor(.secondary)

                        Divider()

                        Text("Excluded folders")
                            .font(.caption).fontWeight(.medium)
                        TextField(".obsidian, .git, .trash", text: Binding(
                            get: { syncManager.config.excludedFolders.joined(separator: ", ") },
                            set: { syncManager.config.excludedFolders = $0.split(separator: ",").map { String($0.trimmingCharacters(in: .whitespaces)) } }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                    }
                    .padding(4)
                }

                // Tag → List mappings
                GroupBox("Tag → Reminders List Mappings") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Map Obsidian #tags to specific Reminders lists. Unmapped tags auto-capitalize (e.g. #work → Work).")
                            .font(.caption2).foregroundColor(.secondary)

                        ForEach(syncManager.config.listMappings.indices, id: \.self) { index in
                            HStack {
                                Text("#\(syncManager.config.listMappings[index].obsidianTag)")
                                    .font(.system(size: 12, design: .monospaced))
                                Image(systemName: "arrow.right")
                                    .font(.caption2).foregroundColor(.secondary)
                                Text(syncManager.config.listMappings[index].remindersList)
                                    .font(.system(size: 12))
                                Spacer()
                                Button(action: { syncManager.config.listMappings.remove(at: index) }) {
                                    Image(systemName: "minus.circle.fill").foregroundColor(.red)
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        HStack(spacing: 4) {
                            TextField("#tag", text: $newMappingTag)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12))
                            Image(systemName: "arrow.right")
                                .font(.caption2).foregroundColor(.secondary)
                            TextField("List Name", text: $newMappingList)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12))
                            Button(action: {
                                let tag = newMappingTag.hasPrefix("#") ? String(newMappingTag.dropFirst()) : newMappingTag
                                guard !tag.isEmpty, !newMappingList.isEmpty else { return }
                                syncManager.config.listMappings.append(
                                    SyncConfiguration.ListMapping(obsidianTag: tag, remindersList: newMappingList)
                                )
                                newMappingTag = ""
                                newMappingList = ""
                            }) {
                                Image(systemName: "plus.circle.fill").foregroundColor(.green)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(4)
                }
            }
            .padding(.horizontal, 30)
        }
    }

    private var finishStep: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "sparkles")
                .font(.system(size: 48))
                .foregroundColor(.accentColor)

            Text("You're All Set!")
                .font(.title2)
                .fontWeight(.semibold)

            VStack(alignment: .leading, spacing: 8) {
                Label(syncManager.config.vaultPath.isEmpty ? "No vault selected" : "Vault: \(URL(fileURLWithPath: syncManager.config.vaultPath).lastPathComponent)",
                      systemImage: syncManager.config.vaultPath.isEmpty ? "xmark.circle" : "checkmark.circle.fill")
                    .foregroundColor(syncManager.config.vaultPath.isEmpty ? .red : .green)
                    .font(.caption)

                Label(syncManager.hasRemindersAccess ? "Reminders access granted" : "Reminders access needed",
                      systemImage: syncManager.hasRemindersAccess ? "checkmark.circle.fill" : "xmark.circle")
                    .foregroundColor(syncManager.hasRemindersAccess ? .green : .red)
                    .font(.caption)

                Label("Auto-sync every \(syncManager.config.syncIntervalMinutes) minutes",
                      systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Label("Completion writeback \(syncManager.config.enableCompletionWriteback ? "enabled" : "disabled")",
                      systemImage: syncManager.config.enableCompletionWriteback ? "checkmark.circle.fill" : "circle")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 60)

            Text("You can change these settings anytime from the menu bar icon.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Spacer()
        }
    }

    // MARK: - Helpers

    private var canAdvance: Bool {
        switch currentStep {
        case 1: return !syncManager.config.vaultPath.isEmpty
        case 2: return syncManager.hasRemindersAccess
        default: return true
        }
    }

    private func completeOnboarding() {
        // Mark onboarding as complete
        UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
        syncManager.config.save()

        // Trigger first sync if both vault and reminders are configured
        if !syncManager.config.vaultPath.isEmpty && syncManager.hasRemindersAccess {
            Task {
                await syncManager.performSync()
            }
        }

        isPresented = false
    }
}
