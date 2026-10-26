import XCTest
@testable import LoveployCore

final class SessionGroupTests: XCTestCase {
    func testLayouts() {
        XCTAssertEqual(PaneLayout.grid.rows(for: 0), [])
        XCTAssertEqual(PaneLayout.grid.rows(for: 1), [1])
        XCTAssertEqual(PaneLayout.grid.rows(for: 3), [3])
        XCTAssertEqual(PaneLayout.grid.rows(for: 4), [2, 2])
        XCTAssertEqual(PaneLayout.grid.rows(for: 5), [3, 2])
        XCTAssertEqual(PaneLayout.grid.rows(for: 8), [4, 4])
        XCTAssertEqual(PaneLayout.columns.rows(for: 5), [5])
        XCTAssertEqual(PaneLayout.rows.rows(for: 3), [1, 1, 1])
        XCTAssertEqual(PaneLayout.focus.rows(for: 4), [1, 1, 1], "three stacked next to the big one")
        for layout in PaneLayout.allCases {
            for count in 1...SessionGroup.maxPanes {
                let shown = layout.rows(for: count).reduce(0, +) + (layout == .focus ? 1 : 0)
                XCTAssertEqual(shown, count, "\(layout) with \(count)")
            }
        }
    }

    func testGroupsHoldEightPanesAtMost() {
        var group = SessionGroup(name: "Mañana")
        for i in 0..<8 {
            XCTAssertTrue(group.add(SessionPane(kind: .local, title: "s\(i)")))
        }
        XCTAssertTrue(group.isFull)
        XCTAssertFalse(group.add(SessionPane(kind: .local, title: "nueve")))
        XCTAssertEqual(group.panes.count, 8)

        let tooMany = SessionGroup(name: "x", panes: (0..<10).map { SessionPane(kind: .cloud, title: "\($0)") })
        XCTAssertEqual(tooMany.panes.count, 8)
    }

    func testMoveAndRemove() {
        var group = SessionGroup(name: "g")
        let a = SessionPane(kind: .local, title: "a"), b = SessionPane(kind: .local, title: "b"), c = SessionPane(kind: .local, title: "c")
        [a, b, c].forEach { group.add($0) }
        group.move(c.id, by: -1)
        XCTAssertEqual(group.panes.map(\.title), ["a", "c", "b"])
        group.move(a.id, by: -1)
        XCTAssertEqual(group.panes.map(\.title), ["a", "c", "b"], "can't move past the edge")
        group.remove(c.id)
        XCTAssertEqual(group.panes.map(\.title), ["a", "b"])
        var renamed = b
        renamed.title = "B"
        group.replace(renamed)
        XCTAssertEqual(group.panes.map(\.title), ["a", "B"])
    }

    func testShellCommandAndEnvironment() {
        let pane = SessionPane(kind: .local, title: "t", sessionID: "abc-123", directory: "/Users/ale/Mi App's", configDir: "/Users/ale/.claude-work")
        XCTAssertEqual(pane.shellCommand, #"cd '/Users/ale/Mi App'\''s' && exec claude --resume 'abc-123'"#)
        XCTAssertEqual(pane.environment, ["CLAUDE_CONFIG_DIR": "/Users/ale/.claude-work"])
        let fresh = SessionPane(kind: .local, title: "nueva", directory: "/tmp")
        XCTAssertEqual(fresh.shellCommand, "cd '/tmp' && exec claude")
        XCTAssertEqual(fresh.environment, [:])
    }

    func testCloudPanesOnlyAcceptClaudeAddresses() {
        let pane = SessionPane.cloud(" https://claude.ai/code/session_01AbCdEfGh ", title: nil, account: "p1")
        XCTAssertEqual(pane?.url, "https://claude.ai/code/session_01AbCdEfGh")
        XCTAssertEqual(pane?.title, "Sesión 01AbCd")
        XCTAssertEqual(pane?.account, "p1")
        XCTAssertEqual(SessionPane.cloud("https://claude.ai/code", title: "Nueva", account: nil)?.title, "Nueva")
        XCTAssertNil(SessionPane.cloud("https://evil.example.com/claude.ai", title: nil, account: nil))
        XCTAssertNil(SessionPane.cloud("http://claude.ai/code", title: nil, account: nil))
    }

    func testStoreRoundTripAndLenientFiles() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("groups.json")
        let store = SessionGroupStore(fileURL: url)
        XCTAssertEqual(store.load(), [])
        var group = SessionGroup(name: "Lovable", layout: .focus, openAtLaunch: true)
        group.add(SessionPane(kind: .cloud, title: "nube", account: "p", url: "https://claude.ai/code"))
        group.add(SessionPane(kind: .local, title: "local", sessionID: "s1", directory: "/tmp"))
        try store.save([group])
        XCTAssertEqual(store.load(), [group])

        try Data(#"[{"name":"Viejo","panes":[{"kind":"cloud","url":"https://claude.ai/code","extra":1},{}],"layout":"nuevo"}]"#.utf8).write(to: url)
        let old = store.load()
        XCTAssertEqual(old.first?.name, "Viejo")
        XCTAssertEqual(old.first?.panes.count, 2)
        XCTAssertEqual(old.first?.layout, .grid)
    }

    func testScansLocalSessions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("projects")
        let project = root.appendingPathComponent("-Users-ale-loveploy")
        try FileManager.default.createDirectory(at: project.appendingPathComponent("s2/subagents"), withIntermediateDirectories: true)

        func write(_ name: String, _ lines: [String], age: TimeInterval) throws {
            let file = project.appendingPathComponent(name)
            try lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: file.path)
        }
        try write("s1.jsonl", [
            #"{"type":"user","isMeta":true,"cwd":"/Users/ale/loveploy","message":{"role":"user","content":"<command>"}}"#,
            #"{"type":"user","cwd":"/Users/ale/loveploy","message":{"role":"user","content":[{"type":"text","text":"Haz el modo turbo"}]}}"#,
        ], age: 100)
        try write("s2.jsonl", [
            #"{"type":"user","cwd":"/Users/ale/otra","message":{"role":"user","content":"Primera pregunta"}}"#,
            #"{"customTitle":"Título propio"}"#,
        ], age: 10)
        try write("s2/subagents/agent-1.jsonl", [#"{"type":"user","cwd":"/x","message":{"content":"sub"}}"#], age: 1)
        try write("vacio.jsonl", [#"{"type":"assistant"}"#], age: 5)

        let sessions = LocalSessionScanner.scan(projectsRoot: root, configDir: "/Users/ale/.claude-work", titles: ["s1": "Del escritorio"])
        XCTAssertEqual(sessions.map(\.id), ["s2", "s1"], "newest first, no subagents, no sessions without a folder")
        XCTAssertEqual(sessions[0].title, "Título propio")
        XCTAssertEqual(sessions[0].cwd, "/Users/ale/otra")
        XCTAssertEqual(sessions[1].title, "Del escritorio")
        XCTAssertEqual(sessions[1].project, "loveploy")
        XCTAssertEqual(sessions[1].configDir, "/Users/ale/.claude-work")

        let pane = SessionPane.local(sessions[1], account: "p1")
        XCTAssertEqual(pane.shellCommand, "cd '/Users/ale/loveploy' && exec claude --resume 's1'")
    }
}

final class GroupShortcutTests: XCTestCase {
    func testDisplaySuggestionAndStorage() throws {
        let all = GroupShortcut.command | GroupShortcut.option | GroupShortcut.control
        let first = GroupShortcut.suggestion(taken: [nil])
        XCTAssertEqual(first?.display, "⌃⌥⌘1")
        XCTAssertEqual(first?.keyCode, 0x12)
        let third = GroupShortcut.suggestion(taken: [first, GroupShortcut(keyCode: 0x13, modifiers: all, key: "2"), GroupShortcut(keyCode: 0x13, modifiers: GroupShortcut.command, key: "2")])
        XCTAssertEqual(third?.display, "⌃⌥⌘3")
        XCTAssertEqual(GroupShortcut(keyCode: 5, modifiers: GroupShortcut.shift | GroupShortcut.command, key: "g").display, "⇧⌘G")
        XCTAssertFalse(GroupShortcut(keyCode: 5, modifiers: GroupShortcut.shift, key: "g").isUsable)
        XCTAssertTrue(first!.sameKeys(as: GroupShortcut(keyCode: 0x12, modifiers: all, key: "x")))

        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("groups.json")
        let store = SessionGroupStore(fileURL: url)
        try store.save([SessionGroup(name: "Revisar", shortcut: first)])
        XCTAssertEqual(store.load().first?.shortcut, first)
    }
}

final class ChromeTabTests: XCTestCase {
    func testParsesAndPicksClaudeTabs() {
        let output = """
        101\t1\thttps://claude.ai/new\tClaude
        101\t2\thttps://github.com/alereed/loveploy\tloveploy
        102\t1\thttps://claude.ai/code/session_01AbC?x=1\tArreglar HDMI - Claude
        103\t1\thttps://claude.ai/code/session_01AbC#bottom\tduplicada
        104\t1\thttps://claude.ai/chat/1234\tPlan de lanzamiento | Claude
        roto
        """
        let tabs = ChromeTab.parse(output)
        XCTAssertEqual(tabs.count, 5)
        let claude = ChromeTab.claudeTabs(tabs)
        XCTAssertEqual(claude.map(\.windowID), [102, 101, 104], "code sessions first, one per page, no github")
        XCTAssertTrue(ClaudeLink.samePage("https://claude.ai/code/session_01AbC/", "https://claude.ai/code/session_01AbC?y"))
        XCTAssertFalse(ClaudeLink.samePage("https://claude.ai/code/session_01AbC", "https://claude.ai/code/session_02"))
        let pane = SessionPane.cloud(claude[0].url, title: claude[0].title, account: nil, kind: .chrome)
        XCTAssertEqual(pane?.kind, .chrome)
        XCTAssertEqual(pane?.title, "Arreglar HDMI")
        XCTAssertEqual(SessionPane.cloud(claude[1].url, title: "Claude", account: nil)?.title, "new")
        XCTAssertNil(SessionPane.cloud("https://evil.com", title: nil, account: nil, kind: .chrome))
    }
}
