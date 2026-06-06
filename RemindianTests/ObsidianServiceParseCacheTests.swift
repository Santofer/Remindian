import XCTest
@testable import Remindian

/// Tests for the incremental-scan parse cache added in v5.13.0 (#7).
///
/// The cache is a **pure performance layer**: it lets `scanVault` skip the
/// read+parse of files whose modification date, byte size, and parse signature
/// are all unchanged since the last scan. The governing invariant — and the
/// thing these tests defend — is that a cached scan must produce **exactly** the
/// task set a cold, from-scratch scan would. If that ever diverges, the sync
/// engine could mistake unchanged tasks for deletions, so this is correctness,
/// not just speed.
final class ObsidianServiceParseCacheTests: XCTestCase {

    private var vaultURL: URL!
    private var service: ObsidianService!

    override func setUp() {
        super.setUp()
        vaultURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("remindian-cache-test-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: vaultURL, withIntermediateDirectories: true)
        service = ObsidianService()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: vaultURL)
        service = nil
        vaultURL = nil
        super.tearDown()
    }

    // MARK: - Helpers

    @discardableResult
    private func writeFile(_ name: String, _ content: String) -> String {
        let url = vaultURL.appendingPathComponent(name)
        try! content.write(to: url, atomically: true, encoding: .utf8)
        return name
    }

    private func deleteFile(_ name: String) {
        try? FileManager.default.removeItem(at: vaultURL.appendingPathComponent(name))
    }

    /// Force a known modification date on a file so we can exercise the
    /// mtime-comparison path deterministically (independent of wall-clock).
    private func setModDate(_ name: String, _ date: Date) {
        let url = vaultURL.appendingPathComponent(name)
        try! FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    private func scan() throws -> [SyncTask] {
        try service.scanVault(at: vaultURL.path, excludedFolders: [])
    }

    /// A from-scratch scan with a fresh service instance — the cold-path oracle
    /// that the cached scan must match exactly.
    private func coldScan() throws -> [SyncTask] {
        try ObsidianService().scanVault(at: vaultURL.path, excludedFolders: [])
    }

    private func sortedKeys(_ tasks: [SyncTask]) -> [String] {
        tasks.map {
            let path = $0.obsidianSource?.filePath ?? "?"
            let line = $0.obsidianSource?.lineNumber ?? -1
            return "\(path)#\(line):\($0.title):\($0.isCompleted):\($0.tags.sorted().joined(separator: ","))"
        }.sorted()
    }

    private func assertMatchesColdScan(_ cached: [SyncTask], _ message: String = "", file: StaticString = #filePath, line: UInt = #line) throws {
        let cold = try coldScan()
        XCTAssertEqual(sortedKeys(cached), sortedKeys(cold), message, file: file, line: line)
    }

    // MARK: - Correctness invariant

    func test_unchangedVault_secondScanMatchesAndHitsCache() throws {
        writeFile("a.md", "- [ ] Alpha 📅 2024-01-01\n- [x] Beta ✅ 2024-01-02\n")
        writeFile("b.md", "- [ ] Gamma #work\n")

        let first = try scan()
        XCTAssertEqual(service.lastScanCacheHits, 0, "Cold first scan can't hit the cache.")
        XCTAssertEqual(first.count, 3)

        let second = try scan()
        XCTAssertEqual(service.lastScanCacheHits, 2, "Both unchanged files should be served from cache on the second scan.")
        XCTAssertEqual(sortedKeys(first), sortedKeys(second), "An unchanged vault must yield an identical task set.")
        try assertMatchesColdScan(second, "Cached scan must equal a cold scan.")
    }

    func test_editedFile_reparsesAndPicksUpChange() throws {
        writeFile("a.md", "- [ ] Alpha\n")
        writeFile("b.md", "- [ ] Beta\n")
        _ = try scan() // prime cache

        // Edit a.md: add a task (changes size AND mtime). b.md untouched.
        writeFile("a.md", "- [ ] Alpha\n- [ ] Alpha2\n")
        let after = try scan()

        XCTAssertEqual(service.lastScanCacheHits, 1, "Only the untouched b.md should hit cache; a.md must re-parse.")
        XCTAssertTrue(after.contains { $0.title == "Alpha2" }, "The newly added task must appear after re-parse.")
        try assertMatchesColdScan(after, "After an edit, cached scan must still equal a cold scan.")
    }

    func test_sameSizeEditWithNewerMtime_stillReparses() throws {
        // Worst case for an mtime+size cache: an edit that keeps the byte count
        // identical. We must still detect it via the modification date.
        let name = writeFile("a.md", "- [ ] AAA\n")
        _ = try scan()

        // Replace with same-length content but a different task title, and bump
        // the mtime forward so the change is unambiguous.
        writeFile(name, "- [ ] BBB\n")
        setModDate(name, Date().addingTimeInterval(5))

        let after = try scan()
        XCTAssertEqual(service.lastScanCacheHits, 0, "A newer mtime must invalidate the cache even when the size is unchanged.")
        XCTAssertTrue(after.contains { $0.title == "BBB" })
        XCTAssertFalse(after.contains { $0.title == "AAA" })
        try assertMatchesColdScan(after)
    }

    func test_deletedFile_dropsItsTasksAndCacheEntry() throws {
        writeFile("a.md", "- [ ] Alpha\n")
        writeFile("b.md", "- [ ] Beta\n")
        _ = try scan()

        deleteFile("b.md")
        let after = try scan()

        XCTAssertEqual(after.count, 1, "Beta's task must disappear once b.md is deleted.")
        XCTAssertTrue(after.allSatisfy { $0.title != "Beta" })
        XCTAssertEqual(service.lastScanCacheHits, 1, "Only the surviving a.md should hit cache.")
        try assertMatchesColdScan(after)
    }

    func test_newFile_isParsedFresh() throws {
        writeFile("a.md", "- [ ] Alpha\n")
        _ = try scan()

        writeFile("c.md", "- [ ] Charlie\n")
        let after = try scan()

        XCTAssertEqual(service.lastScanCacheHits, 1, "a.md cached; the new c.md must parse fresh.")
        XCTAssertTrue(after.contains { $0.title == "Charlie" })
        try assertMatchesColdScan(after)
    }

    func test_changingMarkers_invalidatesCacheViaSignature() throws {
        // `[i]` parses as an open task by default but is excluded when listed as
        // an ignored marker. Same bytes, different parse → signature must force
        // a re-parse rather than serving the stale default-marker result.
        writeFile("a.md", "- [i] Info line\n- [ ] Real task\n")

        let defaultScan = try service.scanVault(at: vaultURL.path, excludedFolders: [])
        XCTAssertTrue(defaultScan.contains { $0.title == "Info line" }, "By default `[i]` is treated as a task.")

        let ignoredScan = try service.scanVault(
            at: vaultURL.path,
            excludedFolders: [],
            ignoredMarkers: ["i"]
        )
        XCTAssertEqual(service.lastScanCacheHits, 0, "A changed parse signature must invalidate the cache.")
        XCTAssertFalse(ignoredScan.contains { $0.title == "Info line" }, "`[i]` must now be ignored.")
        XCTAssertTrue(ignoredScan.contains { $0.title == "Real task" })
    }

    func test_clearParseCache_forcesFullReparse() throws {
        writeFile("a.md", "- [ ] Alpha\n")
        writeFile("b.md", "- [ ] Beta\n")
        _ = try scan()
        XCTAssertEqual(try scan().count, 2)
        XCTAssertEqual(service.lastScanCacheHits, 2)

        service.clearParseCache()
        let after = try scan()
        XCTAssertEqual(service.lastScanCacheHits, 0, "After clearParseCache, every file must re-parse.")
        try assertMatchesColdScan(after)
    }

    // MARK: - Fuzz: random edits must always match a cold scan

    func test_fuzz_randomEditsAlwaysMatchColdScan() throws {
        // Seed a small vault.
        var fileContents: [String: String] = [
            "f0.md": "- [ ] t0\n",
            "f1.md": "- [ ] t1\n- [x] done1 ✅ 2024-01-01\n",
            "f2.md": "- [ ] t2 #work\n",
        ]
        for (name, content) in fileContents { writeFile(name, content) }
        _ = try scan()

        // A deterministic pseudo-random sequence (no Date/Math.random — those
        // are fine in tests, but a fixed sequence makes failures reproducible).
        var state: UInt64 = 0x9E3779B97F4A7C15
        func next() -> Int { state = state &* 6364136223846793005 &+ 1442695040888963407; return Int((state >> 33) & 0xFFFF) }

        for step in 0..<40 {
            let op = next() % 4
            let slot = next() % 5
            let name = "f\(slot).md"
            switch op {
            case 0: // create / overwrite
                let content = "- [ ] task-\(step) #t\(slot)\n- [ ] extra-\(next() % 100)\n"
                fileContents[name] = content
                writeFile(name, content)
            case 1: // delete
                if fileContents[name] != nil {
                    fileContents.removeValue(forKey: name)
                    deleteFile(name)
                }
            case 2: // append a line
                let content = (fileContents[name] ?? "") + "- [ ] appended-\(step)\n"
                fileContents[name] = content
                writeFile(name, content)
            default: // no-op (exercises the cache-hit path)
                break
            }

            let cached = try scan()
            try assertMatchesColdScan(cached, "Divergence at fuzz step \(step) (op \(op), \(name)).")
        }
    }
}
