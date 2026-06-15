import SwiftUI

// MARK: - Floating pinned-tasks window (always-on-top mini task manager)
//
// A non-activating, floating NSPanel. The titlebar chrome is built from custom
// SwiftUI views hosted in TITLEBAR ACCESSORIES (not NSToolbar items — those get
// Tahoe's heavy "Liquid Glass" pill). Accessory views are clickable and FLAT, so
// the grouping control is a subtle hairline-outlined pill (no fill) that opens a
// popover with search + the view choices, and refresh is a plain icon. The window
// body is just the task list. (Pinned tasks window — see memory: pinned-window-titlebar)

/// Shared search text, so the popover's search field and the content list stay in sync.
final class PinnedTasksModel: ObservableObject {
    static let shared = PinnedTasksModel()
    @Published var query = ""
}

@MainActor
final class PinnedTasksWindowController: NSObject {
    static let shared = PinnedTasksWindowController()
    private var panel: NSPanel?

    var isOpen: Bool { panel?.isVisible == true }

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
        // Seamless full-height vibrancy under a transparent titlebar. The chrome is
        // SwiftUI in titlebar accessories (clickable + flat), so no toolbar glass.
        p.styleMask = [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel]
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.isFloatingPanel = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.standardWindowButton(.zoomButton)?.isHidden = true
        p.standardWindowButton(.miniaturizeButton)?.isHidden = true

        // Grouping pull-down (with search) — leading, just after the traffic lights.
        let titleAccessory = NSTitlebarAccessoryViewController()
        let titleHost = NSHostingView(rootView: PinnedTitleControl())
        titleHost.frame = NSRect(x: 0, y: 0, width: 150, height: 30)
        titleAccessory.view = titleHost
        titleAccessory.layoutAttribute = .leading
        p.addTitlebarAccessoryViewController(titleAccessory)

        // Refresh — trailing.
        let refreshAccessory = NSTitlebarAccessoryViewController()
        let refreshHost = NSHostingView(rootView: PinnedRefreshControl())
        refreshHost.frame = NSRect(x: 0, y: 0, width: 34, height: 30)
        refreshAccessory.view = refreshHost
        refreshAccessory.layoutAttribute = .trailing
        p.addTitlebarAccessoryViewController(refreshAccessory)

        p.setContentSize(NSSize(width: 320, height: 460))
        p.minSize = NSSize(width: 280, height: 240)
        p.identifier = NSUserInterfaceItemIdentifier("pinned-tasks-window")
        p.setFrameAutosaveName("pinned-tasks-window")
        if p.frame.origin == .zero { p.center() }

        panel = p
        p.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func restoreIfPreviouslyOpen() {
        if UserDefaults.standard.bool(forKey: "pinnedTasksOpen") { show() }
    }
}

// MARK: - Titlebar controls (flat SwiftUI, hosted in accessories)

/// The grouping pull-down: a flat, hairline-outlined pill (no fill) that opens a
/// popover with a search field and the view choices.
private struct PinnedTitleControl: View {
    @AppStorage("pinnedTasksGrouping") private var groupingRaw = PinnedTasksOrganizer.Grouping.flat.rawValue
    @ObservedObject private var model = PinnedTasksModel.shared
    @ObservedObject private var syncManager = SyncManager.shared
    @State private var showOptions = false
    @State private var hovering = false
    @FocusState private var searchFocused: Bool

    private var grouping: PinnedTasksOrganizer.Grouping {
        PinnedTasksOrganizer.Grouping(rawValue: groupingRaw) ?? .flat
    }

    var body: some View {
        Button { showOptions.toggle() } label: {
            HStack(spacing: 4) {
                Text(grouping.label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.primary)
                if !model.query.trimmingCharacters(in: .whitespaces).isEmpty {
                    Image(systemName: "line.3.horizontal.decrease.circle.fill")
                        .font(.system(size: 10)).foregroundColor(.accentColor)
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold)).foregroundColor(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.primary.opacity(hovering ? 0.06 : 0)))   // no fill, faint hover only
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.18), lineWidth: 0.7))  // subtle rounded outline
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Choose a view & search")
        .popover(isPresented: $showOptions, arrowEdge: .bottom) { popover }
    }

    private var popover: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Tasks").font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary)
                Spacer()
                Text("\(syncManager.allOpenTasks.count) open").font(.system(size: 11)).foregroundColor(.secondary)
            }
            .padding(.horizontal, 12).padding(.top, 9).padding(.bottom, 2)

            searchField
                .padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 9)

            Divider()

            VStack(spacing: 0) {
                ForEach(PinnedTasksOrganizer.Grouping.allCases) { g in
                    Button { groupingRaw = g.rawValue } label: {
                        HStack(spacing: 9) {
                            Image(systemName: g.systemImage).font(.system(size: 12)).frame(width: 16).foregroundColor(.secondary)
                            Text(g.label).font(.system(size: 13)).foregroundColor(.primary)
                            Spacer()
                            if g == grouping {
                                Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundColor(.accentColor)
                            }
                        }
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 5)
        }
        .frame(width: 250)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundColor(.secondary)
            TextField("Search title or #tag", text: $model.query)
                .textFieldStyle(.plain).font(.system(size: 12)).focused($searchFocused)
            if !model.query.isEmpty {
                Button { model.query = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color(nsColor: .textBackgroundColor).opacity(0.55)))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .strokeBorder(searchFocused ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.10), lineWidth: 1))
    }
}

/// Flat refresh icon (no fill).
private struct PinnedRefreshControl: View {
    @ObservedObject private var syncManager = SyncManager.shared
    @State private var hovering = false

    var body: some View {
        Group {
            if syncManager.isLoadingAgenda {
                ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 18, height: 18)
            } else {
                Button {
                    Task { await syncManager.refreshAgenda(force: true) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(hovering ? .primary : .secondary)
                        .padding(4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
                .help("Refresh")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - PinnedTasksView (the task list — the window body)

struct PinnedTasksView: View {
    @EnvironmentObject var syncManager: SyncManager
    @AppStorage("pinnedTasksGrouping") private var groupingRaw = PinnedTasksOrganizer.Grouping.flat.rawValue
    @ObservedObject private var model = PinnedTasksModel.shared
    @State private var collapsed: Set<String> = []

    private var grouping: PinnedTasksOrganizer.Grouping {
        PinnedTasksOrganizer.Grouping(rawValue: groupingRaw) ?? .flat
    }
    private var sections: [PinnedTasksOrganizer.Section] {
        PinnedTasksOrganizer.sections(from: syncManager.allOpenTasks, grouping: grouping, now: Date(), query: model.query)
    }

    var body: some View {
        content
            .frame(minWidth: 280, minHeight: 240)
            .background(VisualEffectBackground().ignoresSafeArea())
            .task { await syncManager.refreshAgenda(force: true) }
    }

    @ViewBuilder
    private var content: some View {
        if sections.isEmpty {
            let searching = !model.query.trimmingCharacters(in: .whitespaces).isEmpty
            VStack(spacing: 8) {
                Image(systemName: syncManager.isLoadingAgenda ? "hourglass" : (searching ? "magnifyingglass" : "checkmark.circle"))
                    .font(.system(size: 22)).foregroundColor(.secondary)
                Text(syncManager.isLoadingAgenda ? "Loading…" : (searching ? "No matches" : "No open tasks"))
                    .font(.system(size: 13)).foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
        } else if grouping.isFlat {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(sections.first?.tasks ?? []) { task in
                        PinnedTaskRow(task: task) {
                            Task { await syncManager.completeAgendaItem(task) }
                        }
                        .padding(.horizontal, 6)
                    }
                }
                .padding(.vertical, 6)
            }
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
