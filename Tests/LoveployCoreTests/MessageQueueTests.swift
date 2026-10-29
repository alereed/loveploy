import Foundation
import XCTest
@testable import LoveployCore

final class MessageQueueTests: XCTestCase {
    func testSendsInOrderAndStopsAtPauses() {
        var queue = MessageQueue(items: [
            QueuedMessage(text: "revisa"),
            QueuedMessage(text: "   "),
            QueuedMessage(text: "prueba"),
            .pause(),
            QueuedMessage(text: "publica"),
        ])
        XCTAssertEqual(queue.pendingCount, 4)
        XCTAssertEqual(queue.takeNext()?.text, "revisa")
        XCTAssertEqual(queue.takeNext()?.text, "prueba", "blank messages are skipped")
        XCTAssertNil(queue.takeNext(), "the pause stops the queue")
        XCTAssertTrue(queue.paused)
        XCTAssertEqual(queue.reason, "Pausa en la cola")
        XCTAssertNil(queue.takeNext(), "stays stopped")
        queue.resume()
        XCTAssertEqual(queue.takeNext()?.text, "publica")
        XCTAssertNil(queue.takeNext())
        XCTAssertFalse(queue.paused)
    }

    func testMoveAndStorage() throws {
        var queue = MessageQueue(items: ["a", "b", "c", "d"].map { QueuedMessage(text: $0) })
        queue.move(fromOffsets: [3], toOffset: 0)
        XCTAssertEqual(queue.items.map(\.text), ["d", "a", "b", "c"])
        queue.move(fromOffsets: [0], toOffset: 3)
        XCTAssertEqual(queue.items.map(\.text), ["a", "b", "d", "c"])
        let data = try JSONEncoder().encode([UUID().uuidString: queue])
        XCTAssertEqual(try JSONDecoder().decode([String: MessageQueue].self, from: data).values.first, queue)
        XCTAssertEqual(try JSONDecoder().decode(MessageQueue.self, from: Data("{}".utf8)), MessageQueue())
    }

    func testHookSettingsAndPayloads() throws {
        let pane = UUID()
        let dir = URL(fileURLWithPath: "/Users/ale/Library/Application Support/Loveploy/hooks")
        let json = ClaudeHooks.settings(pane: pane, directory: dir)
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        let hooks = object["hooks"] as! [String: Any]
        XCTAssertEqual(Set(hooks.keys), ["Stop", "Notification", "UserPromptSubmit"])
        let stop = ((hooks["Stop"] as! [[String: Any]])[0]["hooks"] as! [[String: Any]])[0]
        XCTAssertEqual(stop["type"] as? String, "command")
        XCTAssertEqual(stop["command"] as? String, "mkdir -p \"\(dir.path)\" && cat > \"\(dir.path)/\(pane.uuidString).stop.json\"")
        XCTAssertFalse(json.contains("'"), "no single quotes, so the shell quoting stays simple")

        let shell = SessionPane(kind: .local, title: "t", sessionID: "s1", directory: "/tmp").shellCommand(settings: json)
        XCTAssertTrue(shell.hasPrefix("cd '/tmp' && exec claude --resume 's1' --settings '{"))

        XCTAssertTrue(ClaudeHooks.needsYou(Data(#"{"message":"Claude needs your permission to use Bash"}"#.utf8)))
        XCTAssertFalse(ClaudeHooks.needsYou(Data(#"{"message":"Claude is waiting for your input"}"#.utf8)))
        XCTAssertFalse(ClaudeHooks.needsYou(Data(#"{"notification_type":"idle_prompt","message":"x"}"#.utf8)))
        XCTAssertTrue(ClaudeHooks.needsYou(Data(#"{"notification_type":"permission_prompt"}"#.utf8)))
        XCTAssertEqual(ClaudeHooks.transcript(Data(#"{"transcript_path":"/a/b.jsonl"}"#.utf8)), "/a/b.jsonl")
        XCTAssertEqual(terminalSubmission("a\nb"), "\u{1B}[200~a\nb\u{1B}[201~")
    }

    func testChromeShortcutMatch() {
        XCTAssertEqual(ChromeShortcut(name: "AOC", url: "https://claude.ai/code/session_1?x=1#y").match, "https://claude.ai/code/session_1")
    }
}

final class PreviewPaneTests: XCTestCase {
    func testPreviewAddresses() throws {
        XCTAssertEqual(SessionPane.preview("blender.mx/deskflow", title: nil)?.url, "https://blender.mx/deskflow")
        XCTAssertEqual(SessionPane.preview("localhost:5173", title: "App")?.url, "http://localhost:5173")
        XCTAssertEqual(SessionPane.preview("localhost:5173", title: "App")?.title, "App")
        XCTAssertEqual(SessionPane.preview("https://x.lovable.app", title: "")?.kind, .preview)
        XCTAssertNil(SessionPane.preview("ftp://x.com", title: nil))
        let pane = SessionPane.preview("x.com", title: nil)!
        XCTAssertTrue(pane.autoReload)
        let decoded = try JSONDecoder().decode(SessionPane.self, from: JSONEncoder().encode(pane))
        XCTAssertEqual(decoded, pane)
    }
}
