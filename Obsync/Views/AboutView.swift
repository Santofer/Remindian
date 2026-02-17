import SwiftUI

struct AboutView: View {
    private let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "3.2.0"
    private let buildNumber = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "3"
    private let releaseDate = "February 2026"
    private let githubURL = "https://github.com/Santofer/Remindian"
    private let buyMeCoffeeURL = "https://buymeacoffee.com/santofer"

    @StateObject private var updater = UpdaterService.shared

    var body: some View {
        VStack(spacing: 16) {
            // App icon
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .cornerRadius(20)
                .shadow(radius: 4)

            // App name & version
            Text("Remindian")
                .font(.title)
                .fontWeight(.bold)

            Text("Version \(appVersion) (\(buildNumber))")
                .font(.caption)
                .foregroundColor(.secondary)

            // Tagline
            Text("Sync your tasks between Obsidian, Apple Reminders & Things 3")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Divider()
                .frame(width: 240)

            // Author & info
            VStack(spacing: 8) {
                HStack(spacing: 4) {
                    Text("Made by")
                        .foregroundColor(.secondary)
                    Text("Santofer")
                        .fontWeight(.medium)
                }
                .font(.callout)

                HStack(spacing: 4) {
                    Text("Released")
                        .foregroundColor(.secondary)
                    Text(releaseDate)
                        .fontWeight(.medium)
                }
                .font(.callout)

                HStack(spacing: 4) {
                    Image(systemName: "lock.open.fill")
                        .foregroundColor(.green)
                        .font(.caption)
                    Text("Open Source")
                        .fontWeight(.medium)
                }
                .font(.callout)
            }

            Divider()
                .frame(width: 240)

            // Update section
            if updater.updateAvailable {
                VStack(spacing: 6) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.circle.fill")
                            .foregroundColor(.blue)
                        Text("Update available: \(updater.latestVersion)")
                            .fontWeight(.medium)
                    }
                    .font(.callout)

                    if updater.isDownloading {
                        ProgressView(value: updater.downloadProgress)
                            .frame(width: 200)
                        Text("Downloading update...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        Button(action: {
                            Task { await updater.downloadAndInstall() }
                        }) {
                            HStack {
                                Image(systemName: "arrow.down.circle.fill")
                                Text("Install Update")
                            }
                            .frame(width: 200)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            } else {
                Button(action: {
                    Task { await updater.checkForUpdates(silent: false) }
                }) {
                    HStack {
                        if updater.isChecking {
                            ProgressView()
                                .controlSize(.small)
                                .padding(.trailing, 2)
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath")
                        }
                        Text(updater.isChecking ? "Checking..." : "Check for Updates")
                    }
                    .frame(width: 200)
                }
                .buttonStyle(.bordered)
                .disabled(updater.isChecking)

                if updater.upToDate {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.caption)
                        Text("You're up to date!")
                            .fontWeight(.medium)
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                } else if let lastCheck = updater.lastCheckDate {
                    Text("Last checked: \(lastCheck, style: .relative) ago")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            if let error = updater.errorMessage {
                Text(error)
                    .font(.caption2)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
                    .frame(width: 260)
            }

            // Action buttons
            VStack(spacing: 10) {
                Button(action: {
                    if let url = URL(string: githubURL) {
                        NSWorkspace.shared.open(url)
                    }
                }) {
                    HStack {
                        Image(systemName: "chevron.left.forwardslash.chevron.right")
                        Text("View on GitHub")
                    }
                    .frame(width: 200)
                }
                .buttonStyle(.bordered)

                // Buy Me a Coffee button
                Button(action: {
                    if let url = URL(string: buyMeCoffeeURL) {
                        NSWorkspace.shared.open(url)
                    }
                }) {
                    HStack(spacing: 6) {
                        Text("\u{2615}")
                            .font(.body)
                        Text("Buy Me a Coffee")
                            .fontWeight(.medium)
                    }
                    .frame(width: 200)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
            }

            Text("Free and open source under the MIT License")
                .font(.caption2)
                .foregroundColor(.secondary)
                .padding(.top, 2)
        }
        .padding(30)
        .frame(width: 340, height: 580)
    }
}

#Preview {
    AboutView()
}
