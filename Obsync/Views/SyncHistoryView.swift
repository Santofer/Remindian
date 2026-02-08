import SwiftUI

/// Displays a scrollable log of past sync operations with expandable details.
struct SyncHistoryView: View {
    @EnvironmentObject var syncManager: SyncManager

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Sync History")
                    .font(.headline)
                Spacer()
                if !syncManager.syncLog.entries.isEmpty {
                    Button("Clear") {
                        syncManager.clearSyncLog()
                    }
                    .buttonStyle(.borderless)
                    .foregroundColor(.red)
                }
            }

            if syncManager.syncLog.entries.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "clock")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                    Text("No sync history yet")
                        .foregroundColor(.secondary)
                    Text("Sync operations will appear here")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(syncManager.syncLog.entries) { entry in
                    SyncLogRow(entry: entry)
                }
                .listStyle(.inset)
            }
        }
        .padding()
    }
}

struct SyncLogRow: View {
    let entry: SyncLog.SyncLogEntry
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            ForEach(Array(entry.details.enumerated()), id: \.offset) { _, detail in
                HStack(spacing: 6) {
                    Image(systemName: iconForAction(detail.action))
                        .foregroundColor(colorForAction(detail.action))
                        .frame(width: 16)
                    Text(detail.taskTitle)
                        .lineLimit(1)
                        .font(.caption)
                    Spacer()
                    if let path = detail.filePath {
                        Text(path)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    if let error = detail.errorMessage {
                        Text(error)
                            .font(.caption2)
                            .foregroundColor(.red)
                            .lineLimit(1)
                    }
                }
                .padding(.vertical, 1)
            }
        } label: {
            HStack(spacing: 8) {
                Text(entry.timestamp, style: .relative)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: 80, alignment: .leading)

                Spacer()

                if entry.result.created > 0 {
                    Label("\(entry.result.created)", systemImage: "plus.circle.fill")
                        .font(.caption2)
                        .foregroundColor(.green)
                }
                if entry.result.updated > 0 {
                    Label("\(entry.result.updated)", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption2)
                        .foregroundColor(.blue)
                }
                if entry.result.deleted > 0 {
                    Label("\(entry.result.deleted)", systemImage: "minus.circle.fill")
                        .font(.caption2)
                        .foregroundColor(.red)
                }
                if entry.result.completionsWrittenBack > 0 {
                    Label("\(entry.result.completionsWrittenBack)", systemImage: "checkmark.circle.fill")
                        .font(.caption2)
                        .foregroundColor(.purple)
                }
                if entry.result.errorCount > 0 {
                    Label("\(entry.result.errorCount)", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundColor(.red)
                }
                if entry.result.isDryRun {
                    Text("DRY RUN")
                        .font(.caption2)
                        .fontWeight(.medium)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.yellow.opacity(0.3))
                        .cornerRadius(3)
                }

                Text(String(format: "%.1fs", entry.duration))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func iconForAction(_ action: SyncEngine.SyncLogDetail.ActionType) -> String {
        switch action {
        case .created: return "plus.circle.fill"
        case .updated: return "arrow.triangle.2.circlepath"
        case .deleted: return "minus.circle.fill"
        case .completionWriteback: return "checkmark.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        case .skipped: return "forward.fill"
        }
    }

    private func colorForAction(_ action: SyncEngine.SyncLogDetail.ActionType) -> Color {
        switch action {
        case .created: return .green
        case .updated: return .blue
        case .deleted: return .red
        case .completionWriteback: return .purple
        case .error: return .red
        case .skipped: return .gray
        }
    }
}
