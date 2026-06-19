import XCTest
@testable import Remindian

/// #80-class regression: the Calendar Feed (.ics) destination must never trap
/// when the feed file contains duplicate VTODO UIDs. The .ics is externally
/// writable (HTTP server / cloud-sync folder), so a sync-merge, copy-paste, or
/// interrupted write can leave two VTODOs sharing a UID. Building the in-memory
/// store with `Dictionary(uniqueKeysWithValues:)` would fatal-error on the dup
/// key (EXC_BREAKPOINT) during the launch sync — the same crash class as #80.
final class CalendarFeedDestinationTests: XCTestCase {

    private func writeFeed(_ ics: String) throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("remindian-tasks.ics").path
        try ics.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    func test_80_fetchDoesNotTrapOnDuplicateUIDs() async throws {
        // Two VTODO blocks sharing the SAME non-empty UID.
        let ics = """
        BEGIN:VCALENDAR
        VERSION:2.0
        BEGIN:VTODO
        UID:remindian-ABC
        SUMMARY:Task one
        END:VTODO
        BEGIN:VTODO
        UID:remindian-ABC
        SUMMARY:Task one duplicated by a cloud-sync merge
        END:VTODO
        END:VCALENDAR
        """
        let dest = CalendarFeedDestination()
        dest.outputPath = try writeFeed(ics)

        let tasks = try await dest.fetchAllTasks()   // must not trap on the duplicate UID
        XCTAssertEqual(tasks.count, 2, "Both VTODOs are returned; the duplicate UID must not crash the parse")
    }

    func test_80_fetchStillWorksWithUniqueUIDs() async throws {
        let ics = """
        BEGIN:VCALENDAR
        BEGIN:VTODO
        UID:remindian-1
        SUMMARY:First
        END:VTODO
        BEGIN:VTODO
        UID:remindian-2
        SUMMARY:Second
        END:VTODO
        END:VCALENDAR
        """
        let dest = CalendarFeedDestination()
        dest.outputPath = try writeFeed(ics)

        let tasks = try await dest.fetchAllTasks()
        XCTAssertEqual(tasks.count, 2)
    }
}
