import SwiftUI

/// Pre-flight report: what's configured versus what you probably meant.
struct SyncHealthView: View {
    @EnvironmentObject var syncManager: SyncManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if syncManager.isCheckingHealth {
                checking
            } else if let report = syncManager.healthReport {
                if report.findings.isEmpty {
                    allClear
                } else {
                    findings(report)
                }
            } else {
                idle
            }

            Divider()
            footer
        }
        .frame(width: 560, height: 520)
        .task {
            if syncManager.healthReport == nil { await syncManager.runHealthCheck() }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "stethoscope")
                .font(.title2)
                .foregroundColor(.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("Sync Health")
                    .font(.headline)
                Text("Checks your setup without changing anything.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            if let report = syncManager.healthReport, !syncManager.isCheckingHealth {
                summaryBadge(report)
            }
        }
        .padding()
    }

    private func summaryBadge(_ report: SyncHealth.Report) -> some View {
        Group {
            if report.isHealthy {
                Label("Healthy", systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green)
            } else {
                HStack(spacing: 8) {
                    if report.criticalCount > 0 {
                        Label("\(report.criticalCount)", systemImage: "exclamationmark.octagon.fill")
                            .foregroundColor(.red)
                    }
                    if report.warningCount > 0 {
                        Label("\(report.warningCount)", systemImage: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                    }
                }
            }
        }
        .font(.callout)
    }

    private var checking: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Scanning your vault and simulating a sync…")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var idle: some View {
        VStack(spacing: 12) {
            Image(systemName: "stethoscope")
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            Button("Run check") { Task { await syncManager.runHealthCheck() } }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var allClear: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 44))
                .foregroundColor(.green)
            Text("No problems found")
                .font(.headline)
            Text("Your vault, filters, and destination all look consistent.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func findings(_ report: SyncHealth.Report) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(report.findings) { finding in
                    FindingRow(finding: finding)
                }
            }
            .padding()
        }
    }

    private var footer: some View {
        HStack {
            Button {
                Task { await syncManager.runHealthCheck() }
            } label: {
                Label("Re-check", systemImage: "arrow.clockwise")
            }
            .disabled(syncManager.isCheckingHealth)

            Spacer()

            Text("Nothing here changes your data.")
                .font(.caption2)
                .foregroundColor(.secondary)

            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding()
    }
}

private struct FindingRow: View {
    let finding: SyncHealth.Finding

    private var tint: Color {
        switch finding.severity {
        case .critical: return .red
        case .warning:  return .orange
        case .info:     return .secondary
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: finding.severity.symbolName)
                .foregroundColor(tint)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 4) {
                Text(finding.title)
                    .fontWeight(.semibold)

                Text(finding.detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let suggestion = finding.suggestion {
                    Label(suggestion, systemImage: "arrow.turn.down.right")
                        .font(.caption)
                        .foregroundColor(tint)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(tint.opacity(0.06))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(tint.opacity(0.25), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// Open the health report in its own window, mirroring the Preview Changes flow
/// (the menu bar popover dismisses itself on click, so a sheet can't be used).
func openHealthWindow() {
    if NSApp.activationPolicy() == .accessory {
        NSApp.setActivationPolicy(.regular)
    }
    NSApplication.shared.activate(ignoringOtherApps: true)

    for window in NSApplication.shared.windows where window.identifier?.rawValue == "health-window" {
        window.makeKeyAndOrderFront(nil)
        return
    }

    let view = SyncHealthView().environmentObject(SyncManager.shared)
    let hosting = NSHostingController(rootView: view)
    let window = NSWindow(contentViewController: hosting)
    window.identifier = NSUserInterfaceItemIdentifier("health-window")
    window.title = "Sync Health"
    window.setContentSize(NSSize(width: 560, height: 520))
    window.styleMask = [.titled, .closable, .resizable]
    window.minSize = NSSize(width: 460, height: 400)
    window.center()
    window.makeKeyAndOrderFront(nil)
}
