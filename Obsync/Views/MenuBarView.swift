import SwiftUI

// MARK: - MenuBarView
//
// Content of a MenuBarExtra rendered with .menuBarExtraStyle(.window) — a real
// SwiftUI panel, NOT the native NSMenu. The panel auto-sizes to its content via
// an auto-sizing VStack + .frame(width:). NEVER wrap the body or the Today list
// in a ScrollView: it is greedy vertically, has no fixed height to fill in a
// window-style menu, and collapses the panel to zero height (the menu opens
// blank). Cap the Today list to N rows and offer "+N more…" instead.
//
// Each Today task renders on exactly ONE horizontal line (an HStack):
//   [priority dot] [check] [title, truncated] [spacer] [due capsule]
//
// macOS 13+ only. Anything newer must be #available-gated or avoided.

struct MenuBarView: View {
    @EnvironmentObject var syncManager: SyncManager
    @StateObject private var updater = UpdaterService.shared
    @State private var quickAddText = ""
    @FocusState private var quickAddFocused: Bool

    // Typography scale — quiet, considered hierarchy.
    private let rowFont = Font.system(size: 13)
    private let labelFont = Font.system(size: 11, weight: .semibold)

    // Consistent insets so every section optically lines up.
    private let hInset: CGFloat = 12

    private func submitQuickAdd() {
        let text = quickAddText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        quickAddText = ""
        Task { await syncManager.quickAddTask(text) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Opens straight on the actions — "Sync Now" is the first thing you see.
            actions
                .padding(.top, 2)

            sectionDivider

            quickAddField
                .padding(.horizontal, hInset)
                .padding(.vertical, 6)

            sectionDivider

            todaySection
                .padding(.bottom, 4)

            sectionDivider

            // Status hub: the sync badge + "x min ago" + this sync's task counts,
            // all in one place near the bottom (the old top title bar is gone).
            statusSection

            if updater.updateAvailable {
                sectionDivider
                updateBanner
            }

            sectionDivider

            footer
        }
        .padding(.vertical, 6)
        .frame(width: 320)
        .task { await syncManager.refreshAgenda() }
    }

    // MARK: - Status pill

    /// Small colored status pill: a quiet tinted capsule with a leading glyph —
    /// far more expensive-looking than a bare dot, and it carries a word.
    private var statusPill: some View {
        let s = status
        return HStack(spacing: 4) {
            if syncManager.isSyncing {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.7)
                    .frame(width: 8, height: 8)
            } else {
                Circle()
                    .fill(s.color)
                    .frame(width: 6, height: 6)
            }
            Text(s.label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(s.color)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
            Capsule().fill(s.color.opacity(0.14))
        )
        .help(s.tooltip)
    }

    // MARK: - Actions

    @ViewBuilder
    private var actions: some View {
        if syncManager.isSyncing {
            RowButton(icon: "stop.fill", title: "Stop Sync", tint: .red) {
                syncManager.cancelSync()
            }
        } else {
            RowButton(icon: "arrow.triangle.2.circlepath", title: "Sync Now") {
                Task { await syncManager.performSync() }
            }
            .disabled(!syncManager.hasDestinationAccess)

            RowButton(icon: "eye", title: "Preview Changes…") {
                syncManager.previewResult = nil
                openPreviewWindow()
            }
            .disabled(!syncManager.hasDestinationAccess)

            if syncManager.lastSyncUndoCount > 0 {
                RowButton(
                    icon: "arrow.uturn.backward",
                    title: "Undo Last Sync (\(syncManager.lastSyncUndoCount) file\(syncManager.lastSyncUndoCount == 1 ? "" : "s"))"
                ) {
                    syncManager.undoLastSyncVaultChanges()
                }
                .help("Restore the Obsidian files changed by the last sync to their previous content. Reversible — the current content is backed up first.")
            }
        }

        if !syncManager.pendingConflicts.isEmpty {
            RowButton(
                icon: "exclamationmark.triangle.fill",
                title: "\(syncManager.pendingConflicts.count) Conflict\(syncManager.pendingConflicts.count == 1 ? "" : "s")",
                tint: .orange
            ) {
                openMainWindow()
            }
        }

        if syncManager.profileStore.profiles.count > 1 {
            metaLine {
                Text("\(syncManager.profileStore.enabledProfiles.count) of \(syncManager.profileStore.profiles.count) sync profiles enabled")
            }
        }
    }

    private func metaLine<T: View>(@ViewBuilder _ content: () -> T) -> some View {
        content()
            .font(.system(size: 11))
            .foregroundColor(.secondary)
            .padding(.horizontal, hInset)
            .padding(.top, 2)
            .padding(.bottom, 2)
    }

    // MARK: - Quick add

    private var quickAddField: some View {
        HStack(spacing: 7) {
            Image(systemName: "plus.circle.fill")
                .font(.system(size: 13))
                .foregroundColor(quickAddFocused ? .accentColor : .secondary)

            TextField("Add task… e.g. Pay rent friday every month !! #home", text: $quickAddText)
                .textFieldStyle(.plain)
                .font(rowFont)
                .focused($quickAddFocused)
                .onSubmit { submitQuickAdd() }

            if !quickAddText.isEmpty {
                Button(action: submitQuickAdd) {
                    Text("Add")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.accentColor)
                }
                .buttonStyle(.plain)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor).opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(
                    quickAddFocused ? Color.accentColor.opacity(0.55) : Color.primary.opacity(0.10),
                    lineWidth: 1
                )
        )
        .animation(.easeInOut(duration: 0.12), value: quickAddFocused)
        .animation(.easeInOut(duration: 0.12), value: quickAddText.isEmpty)
        .help("Type a task and press Return. Understands dates (\"friday\"), recurrence (\"every month\", \"toutes les 2 semaines\"), priority (!, !!, !!!) and #tags.")
    }

    // MARK: - Today

    private static let maxAgendaRows = 6

    @ViewBuilder
    private var todaySection: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text("TODAY")
                    .font(labelFont)
                    .tracking(0.5)
                    .foregroundColor(.secondary)

                if !syncManager.agenda.isEmpty {
                    Text("\(syncManager.agenda.count)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                }

                Spacer()

                if syncManager.isLoadingAgenda {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.7)
                }
            }
            .padding(.horizontal, hInset)
            .padding(.bottom, 3)

            if syncManager.agenda.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: syncManager.isLoadingAgenda ? "hourglass" : "checkmark.circle")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    Text(syncManager.isLoadingAgenda ? "Loading…" : "Nothing due today")
                        .font(rowFont)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, hInset)
                .padding(.vertical, 4)
            } else {
                ForEach(syncManager.agenda.prefix(Self.maxAgendaRows)) { task in
                    AgendaRow(task: task) {
                        Task { await syncManager.completeAgendaItem(task) }
                    }
                    .padding(.horizontal, 6)
                }

                if syncManager.agenda.count > Self.maxAgendaRows {
                    RowButton(
                        icon: "ellipsis.circle",
                        title: "\(syncManager.agenda.count - Self.maxAgendaRows) more…",
                        tint: .secondary
                    ) {
                        openMainWindow()
                    }
                }
            }
        }
    }

    // MARK: - Last sync results

    /// Status hub — always shown near the bottom. Carries the sync badge, the
    /// DRY-RUN marker, the "x min ago" timing (moved out of the actions list),
    /// and this sync's task counts. This is where the old top title bar's status
    /// pill now lives.
    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                statusPill

                if syncManager.config.dryRunMode {
                    Text("DRY RUN")
                        .font(.system(size: 9, weight: .bold))
                        .tracking(0.4)
                        .foregroundColor(.orange)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.orange.opacity(0.16)))
                }

                Spacer(minLength: 6)

                if let lastSync = syncManager.lastSyncDate {
                    (Text("synced ") + Text(lastSync, style: .relative) + Text(" ago"))
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                } else {
                    Text("not synced yet")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }

            if let result = syncManager.lastSyncResult {
                let none = result.created == 0 && result.updated == 0 && result.deleted == 0
                    && result.completionsWrittenBack == 0 && result.metadataWrittenBack == 0
                if none {
                    Text("No changes last sync")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                } else {
                    HStack(spacing: 8) {
                        resultChip(result.created, "plus", .green, "Created in Reminders")
                        resultChip(result.updated, "arrow.triangle.2.circlepath", .blue, "Updated in Reminders")
                        resultChip(result.deleted, "minus", .red, "Deleted from Reminders")
                        resultChip(result.completionsWrittenBack, "checkmark", .purple, "Completed in Obsidian (writeback)")
                        resultChip(result.metadataWrittenBack, "pencil", .orange, "Metadata written back to Obsidian")
                    }
                }
            }
        }
        .padding(.horizontal, hInset)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func resultChip(_ count: Int, _ icon: String, _ tint: Color, _ help: String) -> some View {
        if count > 0 {
            HStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .bold))
                Text("\(count)")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundColor(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(tint.opacity(0.14)))
            .help(help)
        }
    }

    // MARK: - Update banner

    private var updateBanner: some View {
        Button {
            updater.downloadUpdate()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 14))
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Update available")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.primary)
                    Text("Version \(updater.latestVersion)")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.accentColor.opacity(0.12))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 0) {
            RowButton(icon: "macwindow", title: "Open Main Window") {
                openMainWindow()
            }
            RowButton(icon: "info.circle", title: "About Remindian") {
                openAboutWindow()
            }
            RowButton(icon: "power", title: "Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
    }

    // MARK: - Shared chrome

    private var sectionDivider: some View {
        Divider()
            .padding(.horizontal, hInset)
            .padding(.vertical, 4)
            .opacity(0.6)
    }

    // MARK: - Status model

    private struct Status {
        let label: String
        let color: Color
        let tooltip: String
    }

    private var status: Status {
        if syncManager.isSyncing {
            return Status(label: "Syncing", color: .blue, tooltip: "Sync in progress")
        } else if !syncManager.hasDestinationAccess {
            return Status(label: "No Access", color: .red, tooltip: "No destination access — check configuration in Settings")
        } else if !syncManager.pendingConflicts.isEmpty {
            return Status(label: "Conflicts", color: .orange, tooltip: "Unresolved conflicts — open main window to resolve")
        } else {
            return Status(label: "Synced", color: .green, tooltip: "Everything is synced and up to date")
        }
    }

    // MARK: - Window helpers (kept as-is from the prior implementation)

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

// MARK: - RowButton
//
// A single full-width menu row with a leading SF Symbol, a title, and a subtle
// rounded hover highlight. macOS 13-safe: the hover state is tracked manually
// via .onHover and rendered with a RoundedRectangle behind the content.

private struct RowButton: View {
    let icon: String
    let title: String
    var tint: Color? = nil
    let action: () -> Void

    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 13))
                Spacer(minLength: 0)
            }
            .foregroundColor(tint ?? .primary)
            .opacity(isEnabled ? 1 : 0.4)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.accentColor.opacity(hovering && isEnabled ? 0.14 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .onHover { hovering = $0 }
    }
}

// MARK: - AgendaRow
//
// One Today task on exactly ONE horizontal line:
//   [priority dot] [circular check] [title, truncated] [spacer] [due capsule]
// The check fills with the accent tint on hover; the due capsule is "Today" in
// accent, "Nd late" in red, otherwise "MMM d" in secondary.

private struct AgendaRow: View {
    let task: SyncTask
    let onComplete: () -> Void

    @State private var rowHovering = false
    @State private var checkHovering = false

    var body: some View {
        let overdue = AgendaBuilder.isOverdue(task, now: Date())

        HStack(spacing: 8) {
            priorityDot

            Button(action: onComplete) {
                ZStack {
                    Circle()
                        .strokeBorder(
                            checkHovering ? Color.accentColor : Color.secondary.opacity(0.6),
                            lineWidth: 1.5
                        )
                        .background(
                            Circle().fill(
                                checkHovering ? Color.accentColor.opacity(0.85) : Color.clear
                            )
                        )
                        .frame(width: 15, height: 15)
                    if checkHovering {
                        Image(systemName: "checkmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(.white)
                    }
                }
            }
            .buttonStyle(.plain)
            .onHover { checkHovering = $0 }
            .help("Mark complete")

            Text(task.title)
                .font(.system(size: 13))
                .foregroundColor(.primary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 6)

            duePill(overdue: overdue)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.accentColor.opacity(rowHovering ? 0.08 : 0))
        )
        .contentShape(Rectangle())
        .onHover { rowHovering = $0 }
    }

    // Small leading colored dot encoding priority. `.none` reserves the slot
    // (clear) so titles still align across rows.
    @ViewBuilder
    private var priorityDot: some View {
        Circle()
            .fill(priorityColor)
            .frame(width: 6, height: 6)
            .help(task.priority == .none ? "" : "\(task.priority.displayName) priority")
    }

    private var priorityColor: Color {
        switch task.priority {
        case .high: return .red
        case .medium: return .orange
        case .low: return .blue
        case .none: return .clear
        }
    }

    @ViewBuilder
    private func duePill(overdue: Bool) -> some View {
        if let due = task.dueDate {
            let info = DueInfo.make(for: due, overdue: overdue)
            Text(info.text)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(info.color)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(info.color.opacity(0.14)))
                .fixedSize()
        }
    }
}

// MARK: - DueInfo

private struct DueInfo {
    let text: String
    let color: Color

    static func make(for due: Date, overdue: Bool) -> DueInfo {
        let cal = Calendar.current
        let now = Date()

        if overdue {
            let days = cal.dateComponents([.day], from: cal.startOfDay(for: due), to: cal.startOfDay(for: now)).day ?? 0
            if days >= 1 {
                return DueInfo(text: "\(days)d late", color: .red)
            }
            return DueInfo(text: "Overdue", color: .red)
        }

        if cal.isDateInToday(due) {
            return DueInfo(text: "Today", color: .accentColor)
        }
        if cal.isDateInTomorrow(due) {
            return DueInfo(text: "Tomorrow", color: .secondary)
        }

        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return DueInfo(text: f.string(from: due), color: .secondary)
    }
}

#Preview {
    MenuBarView()
        .environmentObject(SyncManager.shared)
}
