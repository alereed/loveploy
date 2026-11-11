import Foundation
import XCTest
@testable import LoveployCore

final class MemoryPolicyTests: XCTestCase {
    func testProcessTreeMemory() {
        // A shell (100) running claude (101) with two MCP servers (102, 103) and a grandchild (104).
        let table = ProcessTable(psOutput: """
            1     0   9000
          100     1   2048
          101   100 512000
          102   101 102400
          103   101  51200
          104   103  10240
          200     1 307200
          bad line
        """)
        XCTAssertEqual(table.treeBytes(root: 100), (2048 + 512000 + 102400 + 51200 + 10240) * 1024)
        XCTAssertEqual(table.treeCount(root: 100), 5)
        XCTAssertEqual(table.treeBytes(root: 200), 307200 * 1024)
        XCTAssertEqual(table.treeBytes(root: 999), 0)
        XCTAssertEqual(Set(table.descendants(of: 100)), [101, 102, 103, 104])
        XCTAssertEqual(table.descendants(of: 200), [])
    }

    func testPausesTheLeastRecentlyUsedOverTheLimit() {
        let now = Date()
        let a = LoadedPane(id: UUID(), lastUsed: now.addingTimeInterval(-3600))
        let b = LoadedPane(id: UUID(), lastUsed: now.addingTimeInterval(-60))
        let c = LoadedPane(id: UUID(), lastUsed: now.addingTimeInterval(-7200), pausable: false)   // Claude is working
        let d = LoadedPane(id: UUID(), lastUsed: now.addingTimeInterval(-9000), inUse: true)       // open in front of you
        let e = LoadedPane(id: UUID(), lastUsed: now.addingTimeInterval(-1800))
        XCTAssertEqual(MemoryPolicy.overLimit([a, b, c, d, e], limit: 3), [a.id, e.id], "oldest first, never the busy or open ones")
        XCTAssertEqual(MemoryPolicy.overLimit([a, b, c], limit: 3), [])
        XCTAssertEqual(MemoryPolicy.overLimit([a, b, c, d, e], limit: 0), [], "0 = no limit")
        XCTAssertEqual(MemoryPolicy.overLimit([c, d, a], limit: 1), [a.id], "pauses what it can even if that isn't enough")
    }

    func testHeavyAndPressure() {
        let now = Date()
        let gb = 1_073_741_824
        let idleHeavy = LoadedPane(id: UUID(), lastUsed: now.addingTimeInterval(-600), bytes: 3 * gb)
        let recentHeavy = LoadedPane(id: UUID(), lastUsed: now.addingTimeInterval(-10), bytes: 3 * gb)
        let light = LoadedPane(id: UUID(), lastUsed: now.addingTimeInterval(-600), bytes: gb / 2)
        let front = LoadedPane(id: UUID(), lastUsed: now, bytes: 2 * gb, inUse: true)
        let busy = LoadedPane(id: UUID(), lastUsed: now.addingTimeInterval(-600), bytes: 4 * gb, pausable: false)
        let all = [idleHeavy, recentHeavy, light, front, busy]
        XCTAssertEqual(MemoryPolicy.heavy(all, over: 2 * gb, now: now), [idleHeavy.id])
        XCTAssertEqual(MemoryPolicy.heavy(all, over: 0, now: now), [])
        XCTAssertEqual(Set(MemoryPolicy.underPressure(all, critical: false)), [idleHeavy.id, recentHeavy.id, light.id])
        XCTAssertEqual(MemoryPolicy.underPressure(all, critical: true).last, front.id, "what's in front goes last, and only when critical")
        XCTAssertFalse(MemoryPolicy.underPressure(all, critical: true).contains(busy.id))
        XCTAssertEqual(MemoryPolicy.format(3 * gb / 2), "1.5 GB")
        XCTAssertEqual(MemoryPolicy.format(820 * 1_048_576), "820 MB")
    }
}
