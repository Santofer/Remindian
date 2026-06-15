import SwiftUI

// MARK: - Floating pinned-tasks window (always-on-top mini task manager)
//
// A non-activating, floating NSPanel that stays above other windows and on every
// Space. It hosts `PinnedTasksView`, which groups the active profile's open tasks
// by date / priority / tag / recurrence and lets you check them off inline. The
// panel uses a vibrancy background and respects light/dark mode. (Pinned tasks window)

@MainActor
final class PinnedTasksWindowController: NSObject {
    static let shared = PinnedTasksWindowController()
    private var panel: NSPanel?

    var isOpen: Bool { panel?.isVisible == true }

    /// Show if hidden, hide if visible — wired to the menu entry.
    func toggle() {
        if let p = panel, p.isVisible {
            p.close()
            UserDefaults.standard.set(false, forKey: "pinnedTasksOpen")
        } else {
            show()
        }
    }

    func show() {
        UserDefaults.standard.set(true, forKey: "pinnedTasksOpen")
        if let p = panel {
            p.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingController(rootView: PinnedTasksView().environmentObject(SyncManager.shared))
        let p = NSPanel(contentViewController: hosting)
        // Seamless full-height vibrancy. The native title is hidden — a centered
        // clickable control inside the content names the current grouping and
        // opens the filters+search popover (Things-style). The right titlebar
        // accessory holds refresh + count. Non-activating floating panel.
        // (pinned window toolbar)
        p.styleMask = [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel]
        p.title = "Tasks"
        p.titlebarAppearsTransparent = true
        p.titleVisibility = .hidden
        p.isFloatingPanel = true                 // floats above the app's own windows
        p.level = .floating                      // …and above other apps' normal windows
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]  // every Space + over fullscreen
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.isMovableByWindowBackground = true
        p.standardWindowButton(.zoomButton)?.isHidden = true
        p.standardWindowButton(.miniaturizeButton)?.isHidden = true

        // Refresh + count, parked at the right end of the titlebar.
        let accessory = NSTitlebarAccessoryViewController()
        let accessoryView = NSHostingView(rootView: PinnedToolbarAccessory().environmentObject(SyncManager.shared))
        accessoryView.frame = NSRect(x: 0, y: 0, width: 74, height: 28)
        accessory.view = accessoryView
        accessory.layoutAttribute = .trailing
        p.addTitlebarAccessoryViewController(accessory)

        p.setContentSize(NSSize(width: 300, height: 440))
        p.minSize = NSSize(width: 260, height: 220)
        p.identifier = NSUserInterfaceItemIdentifier("pinned-tasks-window")
        p.setFrameAutosaveName("pinned-tasks-window")   // remembers position/size
        if p.frame.origin == .zero { p.center() }

        panel = p
        p.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Reopen on launch if it was open when the app last quit.
    func restoreIfPreviouslyOpen() {
        if UserDefaults.standard.bool(forKey: "pinnedTasksOpen") { show() }
    }
}

// MARK: - PinnedTasksView

struct PinnedTasksView: View {
    @EnvironmentObject var syncManager: SyncManager
    @AppStorage("pinnedTasksGrouping") private var groupingRaw = PinnedTasksOrganizer.Grouping.date.rawValue
    @State private var collapsed: Set<String> = []
    @State private var query = ""
    @State private var showOptions = false
    @FocusState private var searchFocused: Bool

    private var grouping: PinnedTasksOrganizer.Grouping {
        PinnedTasksOrganizer.Grouping(rawValue: groupingRaw) ?? .date
    }
    private var sections: [PinnedTasksOrganizer.Section] {
        PinnedTasksOrganizer.sections(from: syncManager.allOpenTasks, grouping: grouping, now: Date(), query: query)
    }

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            Divider().opacity(0.4)
            content
        }
        .frame(minWidth: 260, minHeight: 220)
        .background(VisualEffectBackground().ignoresSafeArea())
        .ignoresSafeArea(.container, edges: .top)   // let the title row sit in the titlebar strip
        .task { await syncManager.refreshAgenda(force: true) }
    }

    // MARK: Title bar (Things-style centered popup)
    //
    // A centered, clickable control that names the current grouping and opens a
    // popover with the grouping filters + search. The window body then shows only
    // the tasks. The control sits in the titlebar strip — between the traffic
    // lights (left) and the refresh+count accessory (right). (pinned window toolbar)

    private var titleBar: some View {
        HStack {
            Spacer(minLength: 0)
            Button { showOptions.toggle() } label: {
                HStack(spacing: 5) {
                    Text(menuTitle(grouping))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.primary)
                    if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                        Image(systemName: "line.3.horizontal.decrease.circle.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.accentColor)
                            .help("A search filter is active")
                    }
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.primary.opacity(0.07)))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Choose grouping & search")
            .popover(isPresented: $showOptions, arrowEdge: .bottom) { optionsPopover }
            Spacer(minLength: 0)
        }
        .frame(height: 44)
        .frame(maxWidth: .infinity)
    }

    private func menuTitle(_ g: PinnedTasksOrganizer.Grouping) -> String {
        switch g {
        case .date: return "By Date"
        case .priority: return "By Priority"
        case .tag: return "By Tag"
        case .recurrence: return "Recurring"
        }
    }

    // The popover opened from the centered title: search at the top, then the
    // four grouping choices. Both update the list behind it live.
    private var optionsPopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            searchField
                .padding(.horizontal, 10)
                .padding(.top, 10)
                .padding(.bottom, 9)

            Divider()

            VStack(spacing: 0) {
                ForEach(PinnedTasksOrganizer.Grouping.allCases) { g in
                    Button { groupingRaw = g.rawValue } label: {
                        HStack(spacing: 9) {
                            Image(systemName: g.systemImage)
                                .font(.system(size: 12))
                                .frame(width: 16)
                                .foregroundColor(.secondary)
                            Text(menuTitle(g))
                                .font(.system(size: 13))
                                .foregroundColor(.primary)
                            Spacer()
                            if g == grouping {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(.accentColor)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 5)
        }
        .frame(width: 252)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            TextField("Search title or #tag", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($searchFocused)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor).opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(searchFocused ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.10), lineWidth: 1)
        )
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if sections.isEmpty {
            let searching = !query.trimmingCharacters(in: .whitespaces).isEmpty
            VStack(spacing: 8) {
                Image(systemName: syncManager.isLoadingAgenda ? "hourglass" : (searching ? "magnifyingglass" : "checkmark.circle"))
                    .font(.system(size: 22)).foregroundColor(.secondary)
                Text(syncManager.isLoadingAgenda ? "Loading…" : (searching ? "No matches" : "No open tasks"))
                    .font(.system(size: 13)).foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2, pinnedViews: [.sectionHeaders]) {
                    ForEach(sections) { section in
                        Section {
                            if !collapsed.contains(section.id) {
                                ForEach(section.tasks) { task in
                                    PinnedTaskRow(task: task) {
                                        Task { await syncManager.completeAgendaItem(task) }
                                    }
                                    .padding(.horizontal, 6)
                                }
                            }
                        } header: {
                            sectionHeader(section)
                        }
                    }
                }
                .padding(.vertical, 6)
            }
        }
    }

    private func sectionHeader(_ section: PinnedTasksOrganizer.Section) -> some View {
        Button {
            if collapsed.contains(section.id) { collapsed.remove(section.id) }
            else { collapsed.insert(section.id) }
        } label: {
            HStack(spacing: 7) {
                Circle().fill(color(for: section.accent)).frame(width: 7, height: 7)
                Text(section.title)
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.3)
                    .foregroundColor(.primary)
                Text("\(section.tasks.count)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
                Image(systemName: collapsed.contains(section.id) ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(VisualEffectBackground())
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func color(for accent: PinnedTasksOrganizer.SectionAccent) -> Color {
        switch accent {
        case .red: return .red
        case .orange: return .orange
        case .blue: return .blue
        case .green: return .green
        case .purple: return .purple
        case .gray: return .secondary
        case .accent: return .accentColor
        }
    }
}

// MARK: - PinnedTaskRow

private struct PinnedTaskRow: View {
    let task: SyncTask
    let onComplete: () -> Void

    @State private var rowHovering = false
    @State private var checkHovering = false

    var body: some View {
        let overdue = AgendaBuilder.isOverdue(task, now: Date())
        HStack(spacing: 8) {
            Circle().fill(priorityColor).frame(width: 6, height: 6)

            Button(action: onComplete) {
                ZStack {
                    Circle()
                        .strokeBorder(checkHovering ? Color.accentColor : Color.secondary.opacity(0.6), lineWidth: 1.5)
                        .background(Circle().fill(checkHovering ? Color.accentColor.opacity(0.85) : Color.clear))
                        .frame(width: 15, height: 15)
                    if checkHovering {
                        Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).foregroundColor(.white)
                    }
                }
            }
            .buttonStyle(.plain)
            .onHover { checkHovering = $0 }
            .help("Mark complete")

            Text(task.title)
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.tail)

            if task.recurrenceRule?.isEmpty == false {
                Image(systemName: "repeat").font(.system(size: 9, weight: .semibold)).foregroundColor(.secondary)
                    .help("Recurring")
            }

            Spacer(minLength: 6)

            if let due = task.dueDate {
                let info = dueInfo(for: due, overdue: overdue)
                Text(info.text)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(info.color)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(info.color.opacity(0.14)))
                    .fixedSize()
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color.accentColor.opacity(rowHovering ? 0.08 : 0)))
        .contentShape(Rectangle())
        .onHover { rowHovering = $0 }
    }

    private var priorityColor: Color {
        switch task.priority {
        case .high: return .red
        case .medium: return .orange
        case .low: return .blue
        case .none: return .clear
        }
    }

    private func dueInfo(for due: Date, overdue: Bool) -> (text: String, color: Color) {
        let cal = Calendar.current
        if overdue {
            let days = cal.dateComponents([.day], from: cal.startOfDay(for: due),
                                          to: cal.startOfDay(for: Date())).day ?? 0
            return (days >= 1 ? "\(days)d late" : "Overdue", .red)
        }
        if cal.isDateInToday(due) { return ("Today", .accentColor) }
        if cal.isDateInTomorrow(due) { return ("Tomorrow", .secondary) }
        let f = DateFormatter(); f.dateFormat = "MMM d"
        return (f.string(from: due), .secondary)
    }
}

// MARK: - Titlebar accessory (refresh + open-task count)
//
// Hosted in the window's right titlebar accessory, so it sits on the same line
// as the centered "Tasks" title and the close button.

private struct PinnedToolbarAccessory: View {
    @EnvironmentObject var syncManager: SyncManager

    var body: some View {
        HStack(spacing: 7) {
            Spacer(minLength: 0)
            if !syncManager.allOpenTasks.isEmpty {
                Text("\(syncManager.allOpenTasks.count)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
            }
            if syncManager.isLoadingAgenda {
                ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 14)
            } else {
                Button {
                    Task { await syncManager.refreshAgenda(force: true) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Refresh")
            }
        }
        .padding(.trailing, 12)
        .frame(maxHeight: .infinity)
    }
}

// MARK: - Vibrancy background

private struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .menu
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
