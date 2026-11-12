import Foundation

/// Runs the production Claude Code scanner and projection without creating
/// NSApplication, opening a window, or writing user state. The report holds
/// states and tool names only; titles and assistant text are never printed.
@main
enum ClaudeLiveProbe {
    private static let usage = "Usage: diagnose-claude-live.sh [--expect-session ID] [--expect-tool] [--seconds N]"

    static func main() {
        var expectedSession: String?
        var expectTool = false
        var seconds = 3
        var arguments = Array(CommandLine.arguments.dropFirst())
        while !arguments.isEmpty {
            let flag = arguments.removeFirst()
            if flag == "--expect-tool" { expectTool = true; continue }
            guard ["--expect-session", "--seconds"].contains(flag), !arguments.isEmpty else { fail(usage) }
            let value = arguments.removeFirst()
            if flag == "--expect-session" { expectedSession = value.lowercased() }
            else if let number = Int(value), (1...120).contains(number) { seconds = number }
            else { fail(usage) }
        }
        let scanner = ClaudeSessionScanner()
        let source = CodexLiveTaskSource(observer: ClaudeSessionObserver(), origin: .claude)
        var sawTool = false, sawExpected = false
        var registry: [String: Int] = [:]
        for index in 0..<seconds {
            if index > 0 { Thread.sleep(forTimeInterval: 1) }
            let result = scanner.scan()
            source.applyObservation(result, at: Date())
            registry = ["active": result.sessions.filter { $0.runtimeType == "active" }.count,
                        "idle": result.sessions.filter { $0.runtimeType != "active" }.count]
            for task in source.snapshot.tasks where expectedSession == nil || task.id == expectedSession {
                if task.status == .running || task.status == .waiting { sawExpected = true }
                if task.executionDetails?.phase == .tool, task.executionDetails?.toolName != nil { sawTool = true }
            }
        }
        let tasks: [[String: Any]] = source.snapshot.tasks.map { task in
            ["session": String(task.id.prefix(8)), "slot": task.slot, "status": task.status.rawValue,
             "phase": task.executionDetails?.phase.rawValue ?? "none",
             "tool": task.executionDetails?.toolName ?? "",
             "hasProgress": task.executionDetails?.latestUpdate != nil,
             "hasStart": task.startedAt != nil]
        }
        var success = source.isConnected
        if expectedSession != nil { success = success && sawExpected }
        if expectTool { success = success && sawTool }
        report(["success": success, "source": source.snapshot.taskOrigin?.rawValue ?? "unknown",
                "connected": source.isConnected, "registry": registry,
                "displayed": tasks.count, "total": source.totalSessionCount, "tasks": tasks])
        exit(success ? 0 : 1)
    }

    private static func fail(_ message: String) -> Never {
        report(["success": false, "error": message]); exit(2)
    }

    private static func report(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return }
        print(text)
    }
}
