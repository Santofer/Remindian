import SwiftUI
import AppKit

/// Opens the "Preview Changes" window (works from the menu-bar accessory).
func openPreviewWindow() {
    if NSApp.activationPolicy() == .accessory {
        NSApp.setActivationPolicy(.regular)
    }
    NSApplication.shared.activate(ignoringOtherApps: true)

    for window in NSApplication.shared.windows where window.identifier?.rawValue == "preview-window" {
        window.makeKeyAndOrderFront(nil)
        return
    }

    let view = PreviewChangesView().environmentObject(SyncManager.shared)
    let hosting = NSHostingController(rootView: view)
    let window = NSWindow(contentViewController: hosting)
    window.identifier = NSUserInterfaceItemIdentifier("preview-window")
    window.title = "Preview Changes"
    window.setContentSize(NSSize(width: 560, height: 620))
    window.styleMask = [.titled, .closable, .resizable]
    window.minSize = NSSize(width: 460, height: 420)
    window.center()
    window.makeKeyAndOrderFront(nil)
}

private func closePreviewWindow() {
    for window in NSApplication.shared.windows where window.identifier?.rawValue == "preview-window" {
        window.close()
    }
}

/// Shows what the next sync *would* do (a forced dry-run), grouped by action,
/// with an Apply button to run the real sync. (Diff preview)
struct PreviewChangesView: View {
    @EnvironmentObject var syncManager: SyncManager

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 460, minHeight: 420)
        .task {
            // Kick off the preview when the window opens (unless one is ready).
            if syncManager.previewResult == nil && !syncManager.isPreviewing {
                await syncManager.startPreview()
            }
        }
    }

    private var header: some View {
        HStack {
            Image(systemName: "eye")
                .font(.title2)
                .foregroundColor(.accentColor)
            VStack(alignment: .leading) {
                Text("Preview Changes")
                    .font(.headline)
                Text("Nothing is written until you choose Apply.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button {
                Task { await syncManager.startPreview() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(syncManager.isPreviewing)
        }
        .padding()
    }

    @ViewBuilder
    private var content: some View {
        if syncManager.isPreviewing {
            VStack(spacing: 12) {
                Spacer()
                ProgressView()
                Text("Analyzing what would change…")
                    .foregroundColor(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let result = syncManager.previewResult {
            if result.details.isEmpty && result.errors.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 44))
                        .foregroundColor(.green)
                    Text("No changes — everything is already in sync.")
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        summaryBar(result)
                        ForEach(Self.groups, id: \.action) { group in
                            let items = result.details.filter { $0.action == group.action }
                            if !items.isEmpty {
                                changeSection(title: group.title, icon: group.icon, color: group.color, items: items)
                            }
                        }
                        if !result.errors.isEmpty {
                            errorSection(result.errors)
                        }
                    }
                    .padding()
                }
            }
        } else {
            Color.clear
        }
    }

    private func summaryBar(_ result: SyncEngine.SyncResult) -> some View {
        HStack(spacing: 16) {
            stat("Create", result.created, .green)
            stat("Update", result.updated, .blue)
            stat("Delete", result.deleted, .red)
            stat("→ Obsidian", result.completionsWrittenBack + result.metadataWrittenBack, .purple)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }

    private func stat(_ label: String, _ value: Int, _ color: Color) -> some View {
        VStack {
            Text("\(value)").font(.title3).fontWeight(.bold).foregroundColor(value > 0 ? color : .secondary)
            Text(label).font(.caption2).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func changeSection(title: String, icon: String, color: Color, items: [SyncEngine.SyncLogDetail]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("\(title) (\(items.count))", systemImage: icon)
                .font(.subheadline).fontWeight(.semibold).foregroundColor(color)
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .top, spacing: 6) {
                    Text("•").foregroundColor(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(Self.cleanTitle(item.taskTitle)).font(.callout)
                        if let path = item.filePath, !path.isEmpty {
                            Text(path).font(.caption2).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                    }
                }
                .padding(.leading, 4)
            }
        }
    }

    private func errorSection(_ errors: [Error]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Issues (\(errors.count))", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline).fontWeight(.semibold).foregroundColor(.orange)
            ForEach(Array(errors.enumerated()), id: \.offset) { _, error in
                Text("• \(error.localizedDescription)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var footer: some View {
        HStack {
            if let result = syncManager.previewResult {
                Text(result.summary).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            Button("Close") { closePreviewWindow() }
            Button {
                closePreviewWindow()
                Task { await syncManager.performSync() }
            } label: {
                Label("Apply Changes", systemImage: "checkmark")
            }
            .buttonStyle(.borderedProminent)
            .disabled(syncManager.isPreviewing
                      || (syncManager.previewResult?.details.isEmpty ?? true))
        }
        .padding()
    }

    // MARK: - Grouping

    private struct Group { let action: SyncEngine.SyncLogDetail.ActionType; let title: String; let icon: String; let color: Color }
    private static let groups: [Group] = [
        Group(action: .created, title: "Create in destination", icon: "plus.circle", color: .green),
        Group(action: .updated, title: "Update in destination", icon: "pencil.circle", color: .blue),
        Group(action: .deleted, title: "Delete from destination", icon: "minus.circle", color: .red),
        Group(action: .completionWriteback, title: "Mark complete in Obsidian", icon: "checkmark.circle", color: .purple),
        Group(action: .metadataWriteback, title: "Write metadata to Obsidian", icon: "square.and.pencil", color: .orange),
        Group(action: .skipped, title: "Skipped", icon: "arrow.right.circle", color: .secondary),
    ]

    private static func cleanTitle(_ title: String) -> String {
        title.replacingOccurrences(of: "[DRY RUN] ", with: "")
    }
}
