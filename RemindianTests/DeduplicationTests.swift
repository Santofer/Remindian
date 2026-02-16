import XCTest
@testable import Remindian

final class DeduplicationTests: XCTestCase {

    // MARK: - Task ID Generation

    func testStableIdGeneration() {
        let task1 = SyncTask(
            title: "Test task",
            obsidianSource: SyncTask.ObsidianSource(
                filePath: "/test.md",
                lineNumber: 5,
                originalLine: "- [ ] Test task"
            )
        )
        let task2 = SyncTask(
            title: "Test task",
            obsidianSource: SyncTask.ObsidianSource(
                filePath: "/test.md",
                lineNumber: 5,
                originalLine: "- [ ] Test task"
            )
        )

        let id1 = SyncState.generateObsidianId(task: task1)
        let id2 = SyncState.generateObsidianId(task: task2)
        XCTAssertEqual(id1, id2, "Same task content should produce same ID")
    }

    func testDifferentTasksGetDifferentIds() {
        let task1 = SyncTask(
            title: "Task A",
            obsidianSource: SyncTask.ObsidianSource(
                filePath: "/test.md",
                lineNumber: 1,
                originalLine: "- [ ] Task A"
            )
        )
        let task2 = SyncTask(
            title: "Task B",
            obsidianSource: SyncTask.ObsidianSource(
                filePath: "/test.md",
                lineNumber: 2,
                originalLine: "- [ ] Task B"
            )
        )

        let id1 = SyncState.generateObsidianId(task: task1)
        let id2 = SyncState.generateObsidianId(task: task2)
        XCTAssertNotEqual(id1, id2, "Different tasks should have different IDs")
    }

    func testIdStableAcrossLineReordering() {
        // Content-based IDs should be stable even if line numbers change
        let task1 = SyncTask(
            title: "Test task",
            obsidianSource: SyncTask.ObsidianSource(
                filePath: "/test.md",
                lineNumber: 5,
                originalLine: "- [ ] Test task"
            )
        )
        let task2 = SyncTask(
            title: "Test task",
            obsidianSource: SyncTask.ObsidianSource(
                filePath: "/test.md",
                lineNumber: 10,  // Different line number
                originalLine: "- [ ] Test task"
            )
        )

        let id1 = SyncState.generateObsidianId(task: task1)
        let id2 = SyncState.generateObsidianId(task: task2)
        XCTAssertEqual(id1, id2, "Content-hash IDs should be stable across line reordering")
    }

    // MARK: - Task Hash

    func testSameTaskSameHash() {
        let task = SyncTask(
            title: "Test",
            isCompleted: false,
            priority: .high,
            dueDate: Date(timeIntervalSince1970: 1000000)
        )
        let hash1 = SyncState.generateTaskHash(task)
        let hash2 = SyncState.generateTaskHash(task)
        XCTAssertEqual(hash1, hash2)
    }

    func testDifferentCompletionDifferentHash() {
        let task1 = SyncTask(title: "Test", isCompleted: false)
        let task2 = SyncTask(title: "Test", isCompleted: true)
        let hash1 = SyncState.generateTaskHash(task1)
        let hash2 = SyncState.generateTaskHash(task2)
        XCTAssertNotEqual(hash1, hash2)
    }

    // MARK: - Sync State Mapping

    func testAddAndRetrieveMapping() {
        var state = SyncState()
        state.addOrUpdateMapping(
            obsidianId: "obs1",
            remindersId: "rem1",
            obsidianHash: "hash1",
            remindersHash: "hash1"
        )

        XCTAssertEqual(state.mappings.count, 1)
        XCTAssertEqual(state.mappings.first?.obsidianId, "obs1")
        XCTAssertEqual(state.mappings.first?.remindersId, "rem1")
    }

    func testUpdateExistingMapping() {
        var state = SyncState()
        state.addOrUpdateMapping(
            obsidianId: "obs1",
            remindersId: "rem1",
            obsidianHash: "hash1",
            remindersHash: "hash1"
        )
        state.addOrUpdateMapping(
            obsidianId: "obs1",
            remindersId: "rem1",
            obsidianHash: "hash2",
            remindersHash: "hash2"
        )

        XCTAssertEqual(state.mappings.count, 1, "Should update existing mapping, not create duplicate")
    }

    func testRemoveMapping() {
        var state = SyncState()
        state.addOrUpdateMapping(
            obsidianId: "obs1",
            remindersId: "rem1",
            obsidianHash: "hash1",
            remindersHash: "hash1"
        )
        state.removeMapping(obsidianId: "obs1")

        XCTAssertEqual(state.mappings.count, 0)
    }
}
