import SwiftUI

// MARK: - Floating pinned-tasks window (always-on-top mini task manager)
//
// Modelled on the macOS Emoji panel: a BORDERLESS, rounded floating panel with
// fully custom SwiftUI chrome — no native titlebar, traffic lights, toolbar, or
// Tahoe glass. A small custom close button (top-left) + refresh (top-right), a
// full-width search bar below, the task list, and a bottom tab bar of view icons
// with labels (Tasks / Deadlines / Priorities / Tags / Recurring).
// (Pinned tasks window — see memory: pinned-window-titlebar)

/// Shared search text + a way for SwiftUI to close the borderless window.
final class PinnedTasksModel: ObservableObject {
    static let shared = PinnedTasksModel()
    @Published var query = ""
    var onClose: (() -> Void)?
}

/// A borderless panel that can still become key — otherwise the search field
/// never gets the keyboard and typing does nothing. (#pinned search)
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
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

        PinnedTasksModel.shared.onClose = { [weak self] in
            self?.panel?.close()
            UserDefaults.standard.set(false, forKey: "pinnedTasksOpen")
        }

        let hosting = NSHostingController(rootView: PinnedTasksView().environmentObject(SyncManager.shared))
        let p = KeyablePanel(contentViewController: hosting)
        // Borderless rounded floating panel (Emoji-panel style). No .titled → no
        // traffic lights; the SwiftUI content draws everything and clips itself to
        // a rounded rect, so the window reads as a rounded card with a shadow.
        p.styleMask = [.nonactivatingPanel, .resizable]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.isFloatingPanel = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.isMovableByWindowBackground = true

        p.setContentSize(NSSize(width: 320, height: 480))
        p.minSize = NSSize(width: 280, height: 280)
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

// MARK: - PinnedTasksView (the whole panel)

struct PinnedTasksView: View {
    @EnvironmentObject var syncManager: SyncManager
    @AppStorage("pinnedTasksGrouping") private var groupingRaw = PinnedTasksOrganizer.Grouping.flat.rawValue
    @ObservedObject private var model = PinnedTasksModel.shared
    @State private var collapsed: Set<String> = []
    @State private var closeHover = false
    @State private var refreshHover = false

    private var grouping: PinnedTasksOrganizer.Grouping {
        PinnedTasksOrganizer.Grouping(rawValue: groupingRaw) ?? .flat
    }
    private var sections: [PinnedTasksOrganizer.Section] {
        PinnedTasksOrganizer.sections(from: syncManager.allOpenTasks, grouping: grouping, now: Date(), query: model.query)
    }

    var body: some View {
        // Emoji-panel layout: the list fills the whole card; the top bar (close +
        // refresh + search) and the bottom tab bar are translucent overlays via
        // safeAreaInset, so the list scrolls BEHIND them with a frosted blur. No
        // dividers — the material edge is the separation.
        content
            .safeAreaInset(edge: .top, spacing: 0) { topOverlay }
            .safeAreaInset(edge: .bottom, spacing: 0) { tabBar }
            .background(VisualEffectBackground())
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
            )
            .ignoresSafeArea()
            .task { await syncManager.refreshAgenda(force: true) }
    }

    // MARK: Top overlay — close (left) + refresh (right), then the native search bar

    private var topOverlay: some View {
        VStack(spacing: 8) {
            HStack {
                Button { model.onClose?() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundColor(closeHover ? .primary : .secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { closeHover = $0 }
                .help("Close")

                Spacer()

                if syncManager.isLoadingAgenda {
                    ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 16, height: 16)
                } else {
                    Button { Task { await syncManager.refreshAgenda(force: true) } } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(refreshHover ? .primary : .secondary)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { refreshHover = $0 }
                    .help("Refresh")
                }
            }

            NativeSearchField(text: $model.query)
                .frame(height: 24)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 18)   // room for the fade strip below the search bar
        .background(
            // Same vibrancy material as the window body — so the top of the window
            // is the SAME colour as the rest — masked to fade out below the search
            // bar, so rows dissolve in there too (like the bottom filter bar).
            VisualEffectBackground()
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: .black, location: 0.0),
                            .init(color: .black, location: 0.6),
                            .init(color: .clear, location: 1.0),
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                )
        )
    }

    // MARK: Content (task list)

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
                LazyVStack(alignment: .leading, spacing: 2) {
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
                    .font(.system(size: 11, weight: .semibold)).tracking(0.3).foregroundColor(.primary)
                Text("\(section.tasks.count)").font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary)
                Spacer()
                Image(systemName: collapsed.contains(section.id) ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold)).foregroundColor(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Bottom tab bar — view switcher (icon + label)

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(PinnedTasksOrganizer.Grouping.allCases) { g in
                let selected = g == grouping
                Button { groupingRaw = g.rawValue } label: {
                    VStack(spacing: 2) {
                        Image(systemName: g.systemImage).font(.system(size: 14, weight: .medium))
                        Text(g.label).font(.system(size: 9)).lineLimit(1)
                    }
                    .foregroundColor(selected ? .accentColor : .secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(g.label)
            }
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 5)
        .padding(.top, 26)   // fade zone above the icons
        .background(
            // The lighter gradient frost: transparent at the top edge → frosted by
            // the icons. (Back to the .ultraThinMaterial look, with a slightly taller
            // fade zone so the labels stay readable.)
            Rectangle()
                .fill(.ultraThinMaterial)
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0.0),
                            .init(color: .black, location: 0.55),
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                )
        )
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

            Text(task.title).font(.system(size: 13)).lineLimit(1).truncationMode(.tail)

            if task.recurrenceRule?.isEmpty == false {
                Image(systemName: "repeat").font(.system(size: 9, weight: .semibold)).foregroundColor(.secondary)
                    .help("Recurring")
            }

            Spacer(minLength: 6)

            if let due = task.dueDate {
                let info = dueInfo(for: due, overdue: overdue)
                Text(info.text)
                    .font(.system(size: 10, weight: .semibold)).foregroundColor(info.color)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(info.color.opacity(0.14)))
                    .fixedSize()
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
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

// MARK: - Native search field (same as the macOS Emoji panel)

private struct NativeSearchField: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> NSSearchField {
        let f = NSSearchField()
        f.delegate = context.coordinator
        f.placeholderString = "Search"
        f.bezelStyle = .roundedBezel
        f.focusRingType = .none
        f.font = .systemFont(ofSize: 13)
        f.sendsWholeSearchString = false   // live filtering
        f.sendsSearchStringImmediately = true
        return f
    }

    func updateNSView(_ nsView: NSSearchField, context: Context) {
        if nsView.stringValue != text { nsView.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: NativeSearchField
        init(_ parent: NativeSearchField) { self.parent = parent }
        func controlTextDidChange(_ obj: Notification) {
            guard let f = obj.object as? NSSearchField else { return }
            parent.text = f.stringValue
        }
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
