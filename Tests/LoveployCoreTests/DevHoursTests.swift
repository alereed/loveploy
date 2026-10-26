import Foundation
import XCTest
@testable import LoveployCore

final class DevHoursTests: XCTestCase {
    var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Mexico_City")!
        calendar.firstWeekday = 2
        return calendar
    }()

    func line(_ type: String, _ stamp: String) -> String {
        #"{"type":"\#(type)","timestamp":"\#(stamp)","message":{"content":"x"}}"#
    }

    func testCountsFiveMinuteSlotsIncrementally() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = root.appendingPathComponent("-Users-ale-app")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("s1.jsonl")
        // 16:00Z = 10:00 in Mexico City.
        let first = [
            line("user", "2026-10-20T16:00:10.000Z"),
            line("assistant", "2026-10-20T16:03:00.000Z"),   // same slot
            line("assistant", "2026-10-20T16:07:00.000Z"),   // next slot
            #"{"type":"summary","timestamp":"2026-10-20T18:00:00.000Z"}"#,   // not a message
            line("user", "2026-10-20T17:00:00Z"),
        ]
        try (first.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)

        var hours = DevHours()
        hours.scan(roots: [root], now: parseISO8601("2026-10-21T12:00:00Z")!, calendar: calendar)
        let day = parseISO8601("2026-10-20T18:00:00Z")!
        XCTAssertEqual(hours.minutes(on: day, calendar: calendar), 15)

        let handle = try FileHandle(forWritingTo: file)
        handle.seekToEndOfFile()
        handle.write(Data((line("assistant", "2026-10-21T15:00:00Z") + "\n" + #"{"type":"user","timest"#).utf8))
        try handle.close()
        hours.scan(roots: [root], now: parseISO8601("2026-10-21T18:00:00Z")!, calendar: calendar)
        XCTAssertEqual(hours.minutes(on: day, calendar: calendar), 15, "nothing counted twice")
        let now = parseISO8601("2026-10-21T18:00:00Z")!
        XCTAssertEqual(hours.minutes(lastDays: 2, now: now, calendar: calendar), 20)
        XCTAssertEqual(hours.minutes(lastDays: 1, now: now, calendar: calendar), 5)
        XCTAssertEqual(hours.minutesThisWeek(now: now, calendar: calendar), 20, "Monday 19th to Wednesday 21st")

        let store = DevHoursStore(fileURL: root.appendingPathComponent("dev-hours.json"))
        try store.save(hours)
        XCTAssertEqual(store.load(), hours)
    }

    func testForgetsOldDaysAndFormats() {
        var hours = DevHours()
        hours.slots = ["2020-01-01": [1, 2], "2026-10-20": [3]]
        hours.scan(roots: [], keepDays: 30, now: parseISO8601("2026-10-21T12:00:00Z")!, calendar: calendar)
        XCTAssertEqual(Array(hours.slots.keys), ["2026-10-20"])
        XCTAssertEqual(DevHours.format(minutes: 0), "0 min")
        XCTAssertEqual(DevHours.format(minutes: 45), "45 min")
        XCTAssertEqual(DevHours.format(minutes: 120), "2 h")
        XCTAssertEqual(DevHours.format(minutes: 200), "3 h 20 min")
    }
}
