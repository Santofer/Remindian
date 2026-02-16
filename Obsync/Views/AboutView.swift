import SwiftUI

struct AboutView: View {
    private let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "3.1.0"
    private let buildNumber = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "2"
    private let releaseDate = "February 2026"
    private let githubURL = "https://github.com/Santofer/Remindian"
    private let downloadURL = "https://github.com/Santofer/Remindian/releases/latest"

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
                .frame(width: 200)

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
                .frame(width: 200)

            // Action buttons
            VStack(spacing: 10) {
                Button(action: {
                    if let url = URL(string: downloadURL) {
                        NSWorkspace.shared.open(url)
                    }
                }) {
                    HStack {
                        Image(systemName: "arrow.down.circle.fill")
                        Text("Check for Updates")
                    }
                    .frame(width: 180)
                }
                .buttonStyle(.borderedProminent)

                Button(action: {
                    if let url = URL(string: githubURL) {
                        NSWorkspace.shared.open(url)
                    }
                }) {
                    HStack {
                        Image(systemName: "chevron.left.forwardslash.chevron.right")
                        Text("View on GitHub")
                    }
                    .frame(width: 180)
                }
                .buttonStyle(.bordered)
            }

            Text("Free and open source under the MIT License")
                .font(.caption2)
                .foregroundColor(.secondary)
                .padding(.top, 4)
        }
        .padding(30)
        .frame(width: 320, height: 480)
    }
}

#Preview {
    AboutView()
}
