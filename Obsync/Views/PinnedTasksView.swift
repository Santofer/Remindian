import SwiftUI

// MARK: - Floating pinned-tasks window (always-on-top mini task manager)
//
// A non-activating, floating NSPanel with a UNIFIED, TRANSPARENT toolbar so the
// traffic lights, a centered grouping pull-down ("Tasks ⌄"), a search field, and
// a refresh button all sit on ONE line and the toolbar blends seamlessly with the
// vibrancy content below it. Native toolbar items → subtle, no custom glass.
// (Pinned tasks window — see memory: pinned-window-titlebar)

/// Shared search text, so the toolbar's search field and the content list (two
/// separate hosting contexts) stay in sync.
final class PinnedTasksModel: ObservableObject {
    static let shared = PinnedTasksModel()
    @Published var query = ""
}

@MainActor
final class PinnedTasksWindowController: NSObject {
    static let shared = PinnedTasksWindowController()
    private var panel: NSPanel?
    private let toolbarController = PinnedToolbarController()

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
        // fullSizeContentView + transparent titlebar → the vibrancy content fills
        // the whole window, including behind the (transparent) unified toolbar, so
        // the toolbar shade matches the rest of the window. Content insets below
        // the toolbar via the safe area.
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

        let toolbar = NSToolbar(identifier: "pinned-tasks-toolbar")
        toolbar.delegate = toolbarController
        toolbar.centeredItemIdentifier = .pinnedGrouping
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.showsBaselineSeparator = false
        p.toolbar = toolbar
        p.toolbarStyle = .unifiedCompact

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

// MARK: - Toolbar (native items)

extension NSToolbarItem.Identifier {
    static let pinnedGrouping = NSToolbarItem.Identifier("pinnedGrouping")
    static let pinnedSearch = NSToolbarItem.Identifier("pinnedSearch")
    static let pinnedRefresh = NSToolbarItem.Identifier("pinnedRefresh")
}

final class PinnedToolbarController: NSObject, NSToolbarDelegate, NSMenuDelegate, NSSearchFieldDelegate {
    private weak var groupingItem: NSMenuToolbarItem?
    private static let groupingKey = "pinnedTasksGrouping"

    private func currentGrouping() -> PinnedTasksOrganizer.Grouping {
        PinnedTasksOrganizer.Grouping(rawValue: UserDefaults.standard.string(forKey: Self.groupingKey) ?? "flat") ?? .flat
    }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case .pinnedGrouping:
            let item = NSMenuToolbarItem(itemIdentifier: id)
            item.title = currentGrouping().label
            item.showsIndicator = true
            let menu = NSMenu()
            menu.delegate = self
            for g in PinnedTasksOrganizer.Grouping.allCases {
                let mi = NSMenuItem(title: g.label, action: #selector(pickGrouping(_:)), keyEquivalent: "")
                mi.target = self
                mi.representedObject = g.rawValue
                menu.addItem(mi)
            }
            item.menu = menu
            item.label = "View"
            groupingItem = item
            return item

        case .pinnedSearch:
            let item = NSSearchToolbarItem(itemIdentifier: id)
            item.searchField.delegate = self
            item.searchField.placeholderString = "Search"
            item.label = "Search"
            return item

        case .pinnedRefresh:
            let item = NSToolbarItem(itemIdentifier: id)
            item.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh")
            item.label = "Refresh"
            item.toolTip = "Refresh"
            item.isBordered = true
            item.target = self
            item.action = #selector(refresh)
            return item

        default:
            return nil
        }
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.pinnedGrouping, .flexibleSpace, .pinnedSearch, .pinnedRefresh]
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.pinnedGrouping, .pinnedSearch, .pinnedRefresh, .flexibleSpace]
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let current = currentGrouping().rawValue
        for mi in menu.items { mi.state = (mi.representedObject as? String == current) ? .on : .off }
    }

    @objc private func pickGrouping(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let g = PinnedTasksOrganizer.Grouping(rawValue: raw) else { return }
        UserDefaults.standard.set(raw, forKey: Self.groupingKey)
        groupingItem?.title = g.label
    }

    @objc private func refresh() {
        Task { @MainActor in await SyncManager.shared.refreshAgenda(force: true) }
    }

    // Live search.
    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSSearchField else { return }
        let text = field.stringValue
        Task { @MainActor in PinnedTasksModel.shared.query = text }
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
            // "Tasks" mode — one ungrouped list, no section headers.
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
