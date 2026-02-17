import Foundation
import AppKit

/// Lightweight auto-updater that checks GitHub Releases for new versions.
/// Downloads the DMG, mounts it, and replaces the running app — all without
/// opening a browser.
@MainActor
class UpdaterService: ObservableObject {
    static let shared = UpdaterService()

    private let owner = "Santofer"
    private let repo = "Remindian"

    @Published var updateAvailable = false
    @Published var latestVersion: String = ""
    @Published var releaseNotes: String = ""
    @Published var downloadURL: URL?
    @Published var isChecking = false
    @Published var isDownloading = false
    @Published var downloadProgress: Double = 0
    @Published var lastCheckDate: Date?
    @Published var errorMessage: String?
    @Published var upToDate = false

    private var checkTimer: Timer?

    private init() {
        // Check for updates on launch (after a short delay)
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            Task { await self?.checkForUpdates(silent: true) }
        }
        // Check every 24 hours
        startPeriodicCheck()
    }

    // MARK: - Periodic Check

    func startPeriodicCheck() {
        checkTimer?.invalidate()
        checkTimer = Timer.scheduledTimer(withTimeInterval: 24 * 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.checkForUpdates(silent: true)
            }
        }
    }

    // MARK: - Check for Updates

    func checkForUpdates(silent: Bool = false) async {
        guard !isChecking else { return }
        isChecking = true
        errorMessage = nil
        upToDate = false

        defer { isChecking = false }

        do {
            let release = try await fetchLatestRelease()
            let remoteVersion = release.tagName
                .replacingOccurrences(of: "v", with: "")
                .replacingOccurrences(of: "-beta", with: "")

            let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"

            if compareVersions(remoteVersion, isNewerThan: currentVersion) {
                latestVersion = release.tagName
                releaseNotes = release.body ?? ""
                downloadURL = release.assets.first(where: { $0.name.hasSuffix(".dmg") })?.browserDownloadUrl
                updateAvailable = true
                lastCheckDate = Date()

                if !silent {
                    showUpdateNotification()
                }
            } else {
                updateAvailable = false
                lastCheckDate = Date()
                if !silent {
                    upToDate = true
                }
            }
        } catch {
            if !silent {
                errorMessage = "Failed to check for updates: \(error.localizedDescription)"
            }
            debugLog("[Updater] Check failed: \(error)")
        }
    }

    // MARK: - Download and Install

    func downloadAndInstall() async {
        guard let url = downloadURL else {
            errorMessage = "No download URL available"
            return
        }

        isDownloading = true
        downloadProgress = 0
        errorMessage = nil

        do {
            // Download DMG to temp directory
            let tempDir = FileManager.default.temporaryDirectory
            let dmgPath = tempDir.appendingPathComponent("Remindian-update.dmg")

            // Remove existing temp file
            try? FileManager.default.removeItem(at: dmgPath)

            // Download with progress tracking
            let (localURL, _) = try await downloadWithProgress(from: url)

            // Move to expected path
            try? FileManager.default.removeItem(at: dmgPath)
            try FileManager.default.moveItem(at: localURL, to: dmgPath)

            // Mount DMG
            let mountPoint = try await mountDMG(at: dmgPath)

            // Find .app in mounted volume
            let contents = try FileManager.default.contentsOfDirectory(atPath: mountPoint)
            guard let appName = contents.first(where: { $0.hasSuffix(".app") }) else {
                throw UpdateError.appNotFoundInDMG
            }

            let sourceApp = URL(fileURLWithPath: mountPoint).appendingPathComponent(appName)
            let currentApp = Bundle.main.bundleURL

            // Replace the running app
            try replaceApp(from: sourceApp, to: currentApp)

            // Unmount DMG
            unmountDMG(at: mountPoint)

            // Clean up
            try? FileManager.default.removeItem(at: dmgPath)

            // Relaunch
            relaunchApp()

        } catch {
            errorMessage = "Update failed: \(error.localizedDescription)"
            debugLog("[Updater] Download/install failed: \(error)")
        }

        isDownloading = false
    }

    // MARK: - Private Helpers

    private func fetchLatestRelease() async throws -> GitHubRelease {
        let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest")!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw UpdateError.apiError("GitHub API returned non-200 status")
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(GitHubRelease.self, from: data)
    }

    private func downloadWithProgress(from url: URL) async throws -> (URL, URLResponse) {
        let (asyncBytes, response) = try await URLSession.shared.bytes(from: url)
        let totalBytes = response.expectedContentLength

        let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".dmg")
        let fileHandle = try FileHandle(forWritingTo: {
            FileManager.default.createFile(atPath: tempFile.path, contents: nil)
            return tempFile
        }())

        var downloadedBytes: Int64 = 0
        var buffer = Data()
        let bufferSize = 65536

        for try await byte in asyncBytes {
            buffer.append(byte)
            if buffer.count >= bufferSize {
                fileHandle.write(buffer)
                downloadedBytes += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                if totalBytes > 0 {
                    downloadProgress = Double(downloadedBytes) / Double(totalBytes)
                }
            }
        }

        if !buffer.isEmpty {
            fileHandle.write(buffer)
            downloadedBytes += Int64(buffer.count)
        }

        fileHandle.closeFile()
        downloadProgress = 1.0

        return (tempFile, response)
    }

    private func mountDMG(at path: URL) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["attach", path.path, "-nobrowse", "-mountrandom", "/tmp"]

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw UpdateError.mountFailed
        }

        let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        // Parse mount point from hdiutil output (last column of last line)
        let lines = output.components(separatedBy: "\n").filter { !$0.isEmpty }
        guard let lastLine = lines.last else {
            throw UpdateError.mountFailed
        }

        // hdiutil output format: "/dev/diskX\tGUID_partition_scheme\t/tmp/dmg.XXXXXX"
        let components = lastLine.components(separatedBy: "\t")
        guard let mountPoint = components.last?.trimmingCharacters(in: .whitespaces), !mountPoint.isEmpty else {
            throw UpdateError.mountFailed
        }

        return mountPoint
    }

    private func unmountDMG(at mountPoint: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["detach", mountPoint, "-quiet"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
    }

    private func replaceApp(from source: URL, to destination: URL) throws {
        let fileManager = FileManager.default

        // Create a backup
        let backupURL = destination.deletingLastPathComponent().appendingPathComponent("Remindian-backup.app")
        try? fileManager.removeItem(at: backupURL)

        // Use NSWorkspace to replace the app atomically
        let tempDestination = destination.deletingLastPathComponent().appendingPathComponent("Remindian-new.app")
        try? fileManager.removeItem(at: tempDestination)

        // Copy new app
        try fileManager.copyItem(at: source, to: tempDestination)

        // Move current app to backup
        try fileManager.moveItem(at: destination, to: backupURL)

        // Move new app to destination
        try fileManager.moveItem(at: tempDestination, to: destination)

        // Remove backup
        try? fileManager.removeItem(at: backupURL)
    }

    private func relaunchApp() {
        let url = Bundle.main.bundleURL
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", url.path]
        try? task.run()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApp.terminate(nil)
        }
    }

    private func showUpdateNotification() {
        let notification = NSUserNotification()
        notification.title = "Remindian Update Available"
        notification.informativeText = "Version \(latestVersion) is available. Open Remindian to update."
        NSUserNotificationCenter.default.deliver(notification)
    }

    /// Compare two semantic version strings. Returns true if `version` > `current`.
    func compareVersions(_ version: String, isNewerThan current: String) -> Bool {
        let vParts = version.components(separatedBy: ".").compactMap { Int($0) }
        let cParts = current.components(separatedBy: ".").compactMap { Int($0) }

        let maxLen = max(vParts.count, cParts.count)
        for i in 0..<maxLen {
            let v = i < vParts.count ? vParts[i] : 0
            let c = i < cParts.count ? cParts[i] : 0
            if v > c { return true }
            if v < c { return false }
        }
        return false
    }
}

// MARK: - Models

struct GitHubRelease: Codable {
    let tagName: String
    let name: String?
    let body: String?
    let prerelease: Bool
    let assets: [GitHubAsset]
}

struct GitHubAsset: Codable {
    let name: String
    let size: Int
    let browserDownloadUrl: URL
}

// MARK: - Errors

enum UpdateError: LocalizedError {
    case apiError(String)
    case appNotFoundInDMG
    case mountFailed
    case replaceFailed

    var errorDescription: String? {
        switch self {
        case .apiError(let msg): return "GitHub API error: \(msg)"
        case .appNotFoundInDMG: return "Could not find Remindian.app in the downloaded DMG"
        case .mountFailed: return "Failed to mount the downloaded DMG"
        case .replaceFailed: return "Failed to replace the application"
        }
    }
}
