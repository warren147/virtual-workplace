import Foundation

@main
struct ClaudeLiveTests {
    private static var checks = 0

    private static func expect(_ value: @autoclosure () -> Bool, _ description: String) {
        checks += 1
        if !value() { fatalError("FAIL: \(description)") }
    }

    private static func row(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    private static func stamp(_ second: Int) -> String {
        String(format: "2026-01-02T03:04:%02d.000Z", second)
    }

    private static func prompt(_ text: String, session: String, at second: Int, meta: Bool = false) -> [String: Any] {
        ["type": "user", "sessionId": session, "isSidechain": false, "isMeta": meta, "timestamp": stamp(second),
         "message": ["role": "user", "content": text]]
    }

    private static func assistant(_ block: [String: Any], session: String, at second: Int, sidechain: Bool = false) -> [String: Any] {
        ["type": "assistant", "sessionId": session, "isSidechain": sidechain, "timestamp": stamp(second),
         "message": ["role": "assistant", "content": [block]]]
    }

    private static func toolResult(_ id: String, session: String, at second: Int) -> [String: Any] {
        ["type": "user", "sessionId": session, "isSidechain": false, "timestamp": stamp(second),
         "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": id, "content": "SECRET OUTPUT"]]]]
    }

    private static func turnEnd(session: String, at second: Int) -> [String: Any] {
        ["type": "system", "subtype": "turn_duration", "sessionId": session, "isSidechain": false, "timestamp": stamp(second)]
    }

    private static func write(_ rows: [[String: Any]], to url: URL, append: Bool = false) {
        var data = Data()
        for item in rows { data.append(row(item)); data.append(10) }
        if append, let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile(); handle.write(data); try? handle.close()
        } else { try! data.write(to: url) }
    }

    private static func register(_ home: URL, pid: Int, session: String, status: String, cwd: String,
                                 name: String = "derived-name", nameSource: String = "derived", updated: Int = 1,
                                 entrypoint: String = "cli") {
        let object: [String: Any] = ["pid": pid, "sessionId": session, "cwd": cwd, "startedAt": 1_700_000_000_000,
                                     "name": name, "nameSource": nameSource, "status": status,
                                     "statusUpdatedAt": updated, "kind": "interactive", "entrypoint": entrypoint]
        try! row(object).write(to: home.appendingPathComponent("sessions/\(pid).json"))
    }

    static func main() throws {
        // Fixture folders only: never read the user's Claude Code registry,
        // transcripts, settings or credentials.
        let sid = "11111111-2222-3333-4444-555555555555"
        var accumulator = ClaudeTranscriptAccumulator(sessionID: sid)
        expect(accumulator.observation.details == nil, "an empty transcript has no details")
        accumulator.consume(line: row(["type": "ai-title", "aiTitle": "  修复  同步问题 ", "sessionId": sid]))
        expect(accumulator.observation.title == "修复 同步问题", "generated title is flattened")
        accumulator.consume(line: row(prompt("ignored reminder", session: sid, at: 1, meta: true)))
        expect(accumulator.observation.details == nil, "meta rows do not start a turn")
        accumulator.consume(line: row(prompt("do the work", session: sid, at: 2)))
        expect(accumulator.observation.details?.phase == .working && accumulator.observation.startedAt != nil,
               "a prompt starts the turn clock")
        let started = accumulator.observation.startedAt
        accumulator.consume(line: row(assistant(["type": "thinking", "thinking": "PRIVATE REASONING"], session: sid, at: 3)))
        expect(accumulator.observation.details?.phase == .thinking, "a thinking block labels the phase")
        accumulator.consume(line: row(assistant(["type": "tool_use", "id": "t1", "name": "Bash", "input": ["command": "SECRET ARG"]], session: sid, at: 4)))
        accumulator.consume(line: row(assistant(["type": "tool_use", "id": "t2", "name": "mcp__srv__do thing!", "input": [:]], session: sid, at: 4)))
        expect(accumulator.observation.details?.phase == .tool
               && accumulator.observation.details?.toolName == "mcp__srv__dothing (+1)", "parallel tool names are sanitized and counted")
        accumulator.consume(line: row(assistant(["type": "tool_use", "id": "x", "name": "Other"], session: sid, at: 4, sidechain: true)))
        accumulator.consume(line: row(assistant(["type": "tool_use", "id": "y", "name": "Other"], session: "another-session", at: 4)))
        expect(accumulator.observation.details?.toolName == "mcp__srv__dothing (+1)", "sidechain and foreign rows are ignored")
        accumulator.consume(line: row(toolResult("t2", session: sid, at: 5)))
        expect(accumulator.observation.details?.toolName == "Bash", "a returned call is removed")
        accumulator.consume(line: row(toolResult("t1", session: sid, at: 6)))
        expect(accumulator.observation.details?.phase == .working && accumulator.observation.details?.toolName == nil,
               "all calls returned means working again")
        accumulator.consume(line: row(assistant(["type": "text", "text": "已经  改好\n了"], session: sid, at: 7)))
        expect(accumulator.observation.details?.latestUpdate == "已经 改好 了", "visible assistant text becomes progress")
        expect(!accumulator.observation.turnCompleted, "text alone does not complete a turn")
        let encoded = String(data: try JSONEncoder().encode(accumulator.observation.details), encoding: .utf8) ?? ""
        expect(!encoded.contains("SECRET") && !encoded.contains("PRIVATE"), "arguments, results and reasoning never enter details")
        accumulator.consume(line: row(turnEnd(session: sid, at: 8)))
        expect(accumulator.observation.turnCompleted && accumulator.observation.details?.phase == .idle
               && accumulator.observation.startedAt == started, "turn_duration completes the turn")
        accumulator.consume(line: row(prompt("again", session: sid, at: 9)))
        expect(!accumulator.observation.turnCompleted && accumulator.observation.details?.latestUpdate == nil,
               "a new prompt clears the previous turn")
        accumulator.consume(line: row(assistant(["type": "tool_use", "id": "t3", "name": "Read"], session: sid, at: 10)))
        accumulator.consume(line: row(prompt("[Request interrupted by user]", session: sid, at: 11)))
        expect(!accumulator.observation.turnCompleted && accumulator.observation.details?.phase == .idle
               && accumulator.observation.details?.toolName == nil, "an interrupt ends the turn without completing it")
        accumulator.consume(line: Data("not json".utf8))
        expect(accumulator.observation.details?.phase == .idle, "malformed rows are ignored")

        let manager = FileManager.default
        let home = manager.temporaryDirectory.appendingPathComponent("vw-claude-\(UUID().uuidString)", isDirectory: true)
        defer { try? manager.removeItem(at: home) }
        var alive: Set<Int32> = [101, 102, 103, 104, 106, 107]
        let scanner = ClaudeSessionScanner(home: home) { pid, _ in alive.contains(pid) }
        let missing = scanner.scan()
        expect(!missing.isConnected && missing.sessions.isEmpty, "no registry folder means not connected")

        let cwd = "/Users/someone/my.project"
        let project = home.appendingPathComponent("projects/-Users-someone-my-project", isDirectory: true)
        try manager.createDirectory(at: home.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        try manager.createDirectory(at: project, withIntermediateDirectories: true)
        let empty = scanner.scan()
        expect(empty.isConnected && empty.sessions.isEmpty, "an empty registry is connected without sessions")

        let busy = "aaaaaaaa-0000-0000-0000-000000000001", waiting = "aaaaaaaa-0000-0000-0000-000000000002"
        let idle = "aaaaaaaa-0000-0000-0000-000000000003", named = "aaaaaaaa-0000-0000-0000-000000000004"
        let dead = "aaaaaaaa-0000-0000-0000-000000000005"
        register(home, pid: 101, session: busy, status: "busy", cwd: cwd)
        register(home, pid: 102, session: waiting, status: "waiting", cwd: cwd)
        register(home, pid: 103, session: idle, status: "idle", cwd: cwd)
        register(home, pid: 104, session: named, status: "shell", cwd: "/elsewhere", name: "我的会话", nameSource: "user")
        register(home, pid: 105, session: dead, status: "busy", cwd: cwd)
        register(home, pid: 106, session: "../../escape", status: "busy", cwd: cwd)
        register(home, pid: 107, session: "aaaaaaaa-0000-0000-0000-000000000007", status: "busy", cwd: cwd, entrypoint: "sdk-cli")
        try Data("{broken".utf8).write(to: home.appendingPathComponent("sessions/999.json"))
        write([["type": "ai-title", "aiTitle": "真实标题", "sessionId": busy], prompt("go", session: busy, at: 1),
               assistant(["type": "tool_use", "id": "c1", "name": "Edit"], session: busy, at: 2)],
              to: project.appendingPathComponent("\(busy).jsonl"))
        write([prompt("old", session: idle, at: 1), turnEnd(session: idle, at: 2)],
              to: project.appendingPathComponent("\(idle).jsonl"))

        let first = scanner.scan()
        let byID = Dictionary(uniqueKeysWithValues: first.sessions.map { ($0.id, $0) })
        expect(first.isConnected && first.sessions.count == 4, "dead, unsafe, malformed and SDK-driven registry entries are dropped")
        expect(byID[busy]?.runtimeType == "active" && byID[busy]?.title == "真实标题"
               && byID[busy]?.executionDetails?.toolName == "Edit" && byID[busy]?.startedAt != nil,
               "a busy session is active with transcript details and its generated title")
        expect(byID[waiting]?.runtimeType == "idle" && byID[waiting]?.activeFlags == []
               && byID[waiting]?.title == "derived-name", "a dialog parked before observation is idle and falls back to the registry name")
        expect(byID[idle]?.runtimeType == "idle" && byID[idle]?.turnStatus == nil && byID[idle]?.executionDetails == nil,
               "an idle session never seen working is not opened or marked completed")
        expect(byID[named]?.runtimeType == "idle" && byID[named]?.title == "我的会话", "unknown states are idle and user names win")

        let source = CodexLiveTaskSource(observer: ClaudeSessionObserver(home: home), origin: .claude)
        let now = Date()
        source.applyObservation(first, at: now)
        expect(source.snapshot.taskOrigin == .claude && source.isConnected, "the projection is labelled as Claude")
        expect(source.snapshot.tasks.map(\.id) == [busy], "only the working session takes a screen")
        let running = source.snapshot.tasks.first { $0.id == busy }
        expect(running?.status == .running && running?.currentStep == "调用工具 · Edit", "tool detail reaches the screen")
        register(home, pid: 101, session: busy, status: "waiting", cwd: cwd, updated: 2)
        let asking = scanner.scan()
        expect(asking.sessions.first { $0.id == busy }?.activeFlags == ["waitingOnUserInput"],
               "a session seen working that then asks is waiting")
        source.applyObservation(asking, at: now)
        expect(source.snapshot.tasks.first?.status == .waiting
               && source.snapshot.tasks.first?.currentStep == "Claude 正在等你确认", "copy names Claude")

        write([toolResult("c1", session: busy, at: 3), assistant(["type": "text", "text": "完成"], session: busy, at: 4),
               turnEnd(session: busy, at: 5)], to: project.appendingPathComponent("\(busy).jsonl"), append: true)
        register(home, pid: 101, session: busy, status: "idle", cwd: cwd, updated: 3)
        alive.remove(102)
        let second = scanner.scan()
        expect(second.sessions.first { $0.id == busy }?.turnStatus == "completed", "an observed turn end is reported as completed")
        expect(!second.sessions.contains { $0.id == waiting }, "an exited process leaves the registry view")
        source.applyObservation(second, at: now.addingTimeInterval(1))
        expect(source.snapshot.tasks.count == 1 && source.snapshot.tasks[0].status == .completed
               && source.snapshot.completedToday == 1, "a completed turn is counted once")
        source.applyObservation(second, at: now.addingTimeInterval(2))
        expect(source.snapshot.completedToday == 1, "repeated observations do not recount")

        let outside = home.appendingPathComponent("outside.jsonl")
        write([prompt("x", session: named, at: 1)], to: outside)
        let reader = ClaudeTranscriptReader(projectsRoot: home.appendingPathComponent("projects"))
        expect(reader.read(sessionID: named, at: outside.path) == nil, "files outside the projects folder are refused")
        let link = project.appendingPathComponent("\(named).jsonl")
        try manager.createSymbolicLink(at: link, withDestinationURL: outside)
        expect(reader.read(sessionID: named, at: link.path) == nil, "symlinks out of the projects folder are refused")

        print("Claude live tests passed (\(checks) checks)")
    }
}
