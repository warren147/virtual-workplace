import Foundation
import Darwin

struct ClaudeTranscriptObservation: Equatable {
    var details: CodexExecutionDetails?
    var startedAt: Date?
    var title: String?
    /// True only after the transcript recorded the end of the current turn.
    var turnCompleted = false
}

/// A small projection of user-visible Claude Code transcript events. Like the
/// Codex rollout accumulator it never retains a row, tool input, tool output
/// or thinking text; a thinking block only labels the phase.
struct ClaudeTranscriptAccumulator {
    private let sessionID: String
    private var details: CodexExecutionDetails?
    private var startedAt: Date?
    private var title: String?
    private var ended = false
    private var completed = false
    private var calls: [(id: String, name: String)] = []
    var observation: ClaudeTranscriptObservation {
        ClaudeTranscriptObservation(details: details, startedAt: startedAt, title: title, turnCompleted: completed)
    }

    init(sessionID: String) { self.sessionID = sessionID }

    mutating func consume(line: Data) {
        autoreleasepool { consumeRow(line: line) }
    }

    private mutating func consumeRow(line: Data) {
        guard line.count <= ClaudeTranscriptReader.maximumLineBytes,
              let row = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let kind = row["type"] as? String else { return }
        if let rowSession = row["sessionId"] as? String, rowSession != sessionID { return }
        if kind == "ai-title" {
            if let text = Self.publicText(row["aiTitle"], limit: 160) { title = text }
            return
        }
        // Subagent rows share the file in some versions; they are not the
        // main session's turn.
        guard row["isSidechain"] as? Bool != true, let date = Self.date(row["timestamp"]) else { return }
        let message = row["message"] as? [String: Any]
        switch kind {
        case "user":
            guard row["isMeta"] as? Bool != true else { return }
            var prompt: String?
            if let blocks = message?["content"] as? [[String: Any]] {
                let results = blocks.compactMap { block -> String? in
                    guard block["type"] as? String == "tool_result" else { return nil }
                    return boundedID(block["tool_use_id"])
                }
                if !results.isEmpty {
                    let before = calls.count
                    calls.removeAll { results.contains($0.id) }
                    if !ended, calls.count != before { update(at: date, phase: calls.isEmpty ? .working : .tool) }
                    return
                }
                prompt = blocks.first { $0["type"] as? String == "text" }?["text"] as? String
            } else { prompt = message?["content"] as? String }
            guard let prompt, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            if prompt.hasPrefix("[Request interrupted") { endTurn(at: date, completed: false); return }
            startedAt = date
            ended = false; completed = false; calls.removeAll()
            details = CodexExecutionDetails(phase: .working, updatedAt: date)
        case "assistant":
            guard let blocks = message?["content"] as? [[String: Any]] else { return }
            // A stop hook may continue a turn after its duration was written.
            if ended { ended = false; completed = false }
            for block in blocks {
                switch block["type"] as? String {
                case "thinking", "redacted_thinking":
                    update(at: date, phase: calls.isEmpty ? .thinking : .tool)
                case "tool_use":
                    guard let callID = boundedID(block["id"]), let rawName = block["name"] as? String,
                          let name = Self.toolName(rawName) else { continue }
                    calls.removeAll { $0.id == callID }
                    if calls.count >= 64 { calls.removeFirst() }
                    calls.append((callID, name))
                    update(at: date, phase: .tool)
                case "text":
                    guard let text = Self.publicText(block["text"], limit: 320) else { continue }
                    update(at: date, phase: calls.isEmpty ? .working : .tool)
                    details?.latestUpdate = text
                default: continue
                }
            }
        case "system":
            if row["subtype"] as? String == "turn_duration" { endTurn(at: date, completed: true) }
        default: return
        }
    }

    mutating func discardGap() {
        details = nil; startedAt = nil; ended = false; completed = false; calls.removeAll()
    }

    private mutating func endTurn(at date: Date, completed: Bool) {
        calls.removeAll(); ended = true; self.completed = completed
        var next = details ?? CodexExecutionDetails(phase: .idle, updatedAt: date)
        next.phase = .idle; next.toolName = nil; next.updatedAt = date
        details = next
    }

    private mutating func update(at date: Date, phase: CodexExecutionPhase) {
        var next = details ?? CodexExecutionDetails(phase: phase, updatedAt: date)
        next.phase = phase; next.updatedAt = date
        if let latest = calls.last {
            let suffix = calls.count > 1 ? " (+\(calls.count - 1))" : ""
            next.toolName = String(latest.name.prefix(max(0, 120 - suffix.count))) + suffix
        } else { next.toolName = nil }
        details = next
    }

    private func boundedID(_ value: Any?) -> String? {
        guard let string = value as? String, !string.isEmpty, string.utf8.count <= 128 else { return nil }
        return string
    }
    private static func toolName(_ name: String) -> String? {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_./:-"))
        let tool = String(name.unicodeScalars.filter { allowed.contains($0) }.prefix(120))
        return tool.isEmpty ? nil : tool
    }
    static func publicText(_ value: Any?, limit: Int) -> String? {
        guard let string = value as? String else { return nil }
        let flat = string.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !flat.isEmpty else { return nil }
        return String(flat.prefix(limit))
    }
    private static func date(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        dateLock.lock(); defer { dateLock.unlock() }
        return fractionalDate.date(from: string) ?? wholeDate.date(from: string)
    }
    private static let dateLock = NSLock()
    private static let fractionalDate: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let wholeDate: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

/// Bounded, incremental reads only inside the Claude Code projects folder.
/// All state belongs to the observer's serial queue, never the AppKit thread.
final class ClaudeTranscriptReader {
    static let maximumLineBytes = 2 * 1024 * 1024
    private static let readBudget = 2 * 1024 * 1024
    private struct Cursor {
        var path: String
        var inode: UInt64
        var device: UInt64
        var offset: UInt64
        var pending = Data()
        var skipping = false
        var accumulator: ClaudeTranscriptAccumulator
    }
    private let projectsRoot: URL
    private var cursors: [String: Cursor] = [:]

    init(projectsRoot: URL) {
        self.projectsRoot = projectsRoot.standardizedFileURL.resolvingSymlinksInPath()
    }

    func retain(sessionIDs: Set<String>) { cursors = cursors.filter { sessionIDs.contains($0.key) } }
    func isTracking(_ sessionID: String) -> Bool { cursors[sessionID] != nil }

    func read(sessionID: String, at path: String) -> ClaudeTranscriptObservation? {
        guard !sessionID.isEmpty, sessionID.utf8.count <= 128, path.hasPrefix("/") else { return nil }
        let file = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        guard file.path.hasPrefix(projectsRoot.path + "/"), file.lastPathComponent == sessionID + ".jsonl" else {
            cursors.removeValue(forKey: sessionID); return nil
        }
        let descriptor = open(file.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { cursors.removeValue(forKey: sessionID); return nil }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid(), info.st_size >= 0 else {
            cursors.removeValue(forKey: sessionID); return nil
        }
        let size = UInt64(info.st_size), inode = UInt64(info.st_ino), device = UInt64(info.st_dev)
        var cursor = cursors[sessionID]
        if cursor?.path != file.path || cursor?.inode != inode || cursor?.device != device || size < (cursor?.offset ?? 0) {
            let start = size > UInt64(Self.readBudget) ? size - UInt64(Self.readBudget) : 0
            cursor = Cursor(path: file.path, inode: inode, device: device, offset: start,
                            skipping: start > 0, accumulator: ClaudeTranscriptAccumulator(sessionID: sessionID))
        }
        guard var next = cursor else { return nil }
        if size > next.offset {
            // A large burst can hold arbitrary history. Jump to its bounded
            // tail and forget prior activity rather than report a stale tool.
            if size - next.offset > UInt64(Self.readBudget) {
                next.offset = size - UInt64(Self.readBudget); next.pending.removeAll(keepingCapacity: false)
                next.skipping = true; next.accumulator.discardGap()
            }
            let wanted = min(Self.readBudget, Int(size - next.offset))
            var bytes = [UInt8](repeating: 0, count: wanted)
            let count = pread(descriptor, &bytes, wanted, off_t(next.offset))
            guard count >= 0 else { return nil }
            if count > 0 {
                next.offset += UInt64(count)
                consume(Data(bytes.prefix(count)), cursor: &next)
            }
        }
        cursors[sessionID] = next
        return next.accumulator.observation
    }

    private func consume(_ data: Data, cursor: inout Cursor) {
        var beginning = data.startIndex
        while beginning < data.endIndex, let newline = data[beginning...].firstIndex(of: 10) {
            if cursor.skipping { cursor.skipping = false }
            else if cursor.pending.count + data.distance(from: beginning, to: newline) <= Self.maximumLineBytes {
                cursor.pending.append(contentsOf: data[beginning..<newline])
                cursor.accumulator.consume(line: cursor.pending)
            } else { cursor.accumulator.discardGap() }
            cursor.pending.removeAll(keepingCapacity: true)
            beginning = data.index(after: newline)
        }
        if beginning < data.endIndex, !cursor.skipping {
            if cursor.pending.count + data.distance(from: beginning, to: data.endIndex) <= Self.maximumLineBytes {
                cursor.pending.append(contentsOf: data[beginning...])
            } else {
                cursor.pending.removeAll(keepingCapacity: false); cursor.skipping = true
                cursor.accumulator.discardGap()
            }
        }
    }
}

/// One pass over the Claude Code session registry (`sessions/<pid>.json`).
/// The registry supplies identity and run state; the transcript only adds
/// phase, tool name, visible progress and the turn clock. Nothing is written
/// to Claude Code's folder and no hook, setting or credential is touched.
final class ClaudeSessionScanner {
    typealias Liveness = (_ pid: Int32, _ registeredAt: Date?) -> Bool
    private static let maximumRegistryFiles = 256
    private static let maximumRegistryBytes = 64 * 1024
    private static let maximumSessions = 128
    private static let maximumProjectFolders = 4096
    private let sessionsRoot: URL
    private let projectsRoot: URL
    private let isAlive: Liveness
    private let reader: ClaudeTranscriptReader
    private var transcriptPaths: [String: String] = [:]
    private var transcriptMisses: [String: Date] = [:]
    private var seenBusy: Set<String> = []

    init(home: URL? = nil, isAlive: @escaping Liveness = ClaudeSessionScanner.processIsAlive) {
        let claudeHome: URL
        if let home { claudeHome = home }
        else if let path = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], path.hasPrefix("/") {
            claudeHome = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            let userHome = getpwuid(getuid()).flatMap { $0.pointee.pw_dir }.map { String(cString: $0) }
                ?? FileManager.default.homeDirectoryForCurrentUser.path
            claudeHome = URL(fileURLWithPath: userHome).appendingPathComponent(".claude", isDirectory: true)
        }
        sessionsRoot = claudeHome.appendingPathComponent("sessions", isDirectory: true)
        projectsRoot = claudeHome.appendingPathComponent("projects", isDirectory: true)
        self.isAlive = isAlive
        reader = ClaudeTranscriptReader(projectsRoot: projectsRoot)
    }

    func scan(at now: Date = Date()) -> CodexObservationResult {
        autoreleasepool { scanOnce(at: now) }
    }

    private struct Entry {
        var sessionID: String
        var cwd: String
        var name: String
        var nameIsDerived: Bool
        var status: String
        var updatedAt: Double
    }

    private func scanOnce(at now: Date) -> CodexObservationResult {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: sessionsRoot.path) else {
            reader.retain(sessionIDs: []); transcriptPaths.removeAll(); transcriptMisses.removeAll()
            seenBusy.removeAll()
            return CodexObservationResult(sessions: [], isConnected: false,
                                          message: "未找到 Claude Code 会话记录，请先在本机运行 Claude Code")
        }
        var entries: [String: Entry] = [:]
        for name in names.filter({ $0.hasSuffix(".json") }).sorted().prefix(Self.maximumRegistryFiles) {
            guard let entry = entry(at: sessionsRoot.appendingPathComponent(name)) else { continue }
            if let existing = entries[entry.sessionID], existing.updatedAt >= entry.updatedAt { continue }
            entries[entry.sessionID] = entry
        }
        let selected = entries.values.sorted {
            $0.updatedAt != $1.updatedAt ? $0.updatedAt > $1.updatedAt : $0.sessionID < $1.sessionID
        }.prefix(Self.maximumSessions)
        let ids = Set(selected.map(\.sessionID))
        reader.retain(sessionIDs: ids)
        transcriptPaths = transcriptPaths.filter { ids.contains($0.key) }
        transcriptMisses = transcriptMisses.filter { ids.contains($0.key) }
        seenBusy.formIntersection(ids)

        var sessions: [CodexObservedSession] = []
        for entry in selected {
            let busy = entry.status == "busy"
            if busy { seenBusy.insert(entry.sessionID) }
            // A dialog left open in a forgotten terminal is not current work.
            // Waiting only counts for a session this observer saw working.
            let waiting = entry.status == "waiting" && seenBusy.contains(entry.sessionID)
            var observation: ClaudeTranscriptObservation?
            // Idle sessions that were never seen working are not opened at all.
            if busy || waiting || reader.isTracking(entry.sessionID),
               let path = transcriptPath(for: entry, at: now) {
                observation = reader.read(sessionID: entry.sessionID, at: path)
            }
            let title = !entry.nameIsDerived && !entry.name.isEmpty ? entry.name
                : observation?.title ?? entry.name
            var session = CodexObservedSession(id: entry.sessionID, title: title,
                                               runtimeType: busy || waiting ? "active" : "idle",
                                               activeFlags: waiting ? ["waitingOnUserInput"] : [])
            session.executionDetails = observation?.details
            session.startedAt = observation?.startedAt
            if !busy, !waiting, observation?.turnCompleted == true { session.turnStatus = "completed" }
            sessions.append(session)
        }
        sessions.sort { $0.id < $1.id }
        return CodexObservationResult(sessions: sessions, isConnected: true,
                                      message: "已连接 Claude Code · 本机 \(sessions.count) 个会话进程")
    }

    private func entry(at url: URL) -> Entry? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.intValue > 0, size.intValue <= Self.maximumRegistryBytes,
              let data = try? Data(contentsOf: url),
              let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sessionID = row["sessionId"] as? String, Self.isSafeID(sessionID),
              let pid = (row["pid"] as? NSNumber)?.int32Value, pid > 1 else { return nil }
        // Sessions driven through the SDK belong to plugins and automation,
        // not to a person at a terminal or in the desktop app.
        if let entrypoint = row["entrypoint"] as? String, entrypoint.hasPrefix("sdk") { return nil }
        let registeredAt = (row["startedAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        // A registry file can outlive a crashed process; its status is then stale.
        guard isAlive(pid, registeredAt) else { return nil }
        let name = ClaudeTranscriptAccumulator.publicText(row["name"], limit: 160) ?? ""
        return Entry(sessionID: sessionID, cwd: row["cwd"] as? String ?? "", name: name,
                     nameIsDerived: (row["nameSource"] as? String ?? "derived") == "derived",
                     status: row["status"] as? String ?? "idle",
                     updatedAt: (row["statusUpdatedAt"] as? NSNumber ?? row["updatedAt"] as? NSNumber)?.doubleValue ?? 0)
    }

    private static func isSafeID(_ value: String) -> Bool {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return !value.isEmpty && value.utf8.count <= 64 && value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private func transcriptPath(for entry: Entry, at now: Date) -> String? {
        let file = entry.sessionID + ".jsonl"
        if let known = transcriptPaths[entry.sessionID] { return known }
        if let missed = transcriptMisses[entry.sessionID], now.timeIntervalSince(missed) < 15 { return nil }
        let manager = FileManager.default
        // Claude Code names the project folder after the launch directory.
        let slug = String(entry.cwd.unicodeScalars.map { scalar -> Character in
            scalar.isASCII && CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : "-"
        })
        var found: String?
        if !slug.isEmpty {
            let direct = projectsRoot.appendingPathComponent(slug).appendingPathComponent(file).path
            if manager.fileExists(atPath: direct) { found = direct }
        }
        if found == nil, let folders = try? manager.contentsOfDirectory(atPath: projectsRoot.path) {
            for folder in folders.prefix(Self.maximumProjectFolders) {
                let candidate = projectsRoot.appendingPathComponent(folder).appendingPathComponent(file).path
                if manager.fileExists(atPath: candidate) { found = candidate; break }
            }
        }
        if let found { transcriptPaths[entry.sessionID] = found; transcriptMisses.removeValue(forKey: entry.sessionID) }
        else { transcriptMisses[entry.sessionID] = now }
        return found
    }

    /// A PID that was reused by a process born after the registry entry is not
    /// the registered session.
    static func processIsAlive(pid: Int32, registeredAt: Date?) -> Bool {
        guard kill(pid, 0) == 0 || errno == EPERM else { return false }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var query = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&query, UInt32(query.count), &info, &size, nil, 0) == 0, size > 0 else { return true }
        let born = info.kp_proc.p_un.__p_starttime
        guard born.tv_sec > 0, let registeredAt else { return true }
        return Double(born.tv_sec) <= registeredAt.timeIntervalSince1970 + 10
    }
}

/// Polls the local Claude Code session registry once a second on a utility
/// queue and publishes only changed observations to the main thread.
final class ClaudeSessionObserver: LiveSessionObserver {
    var onUpdate: ((CodexObservationResult) -> Void)?
    private let queue = DispatchQueue(label: "virtual-workplace.claude-observer", qos: .utility)
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var generation = 0
    private let home: URL?

    init(home: URL? = nil) { self.home = home }
    deinit { stop() }

    func start() {
        lock.lock(); defer { lock.unlock() }
        guard timer == nil else { return }
        generation += 1
        let current = generation
        let scanner = ClaudeSessionScanner(home: home)
        var last: CodexObservationResult?
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now(), repeating: 1.0, leeway: .milliseconds(200))
        source.setEventHandler { [weak self] in
            let result = scanner.scan(at: Date())
            guard result != last else { return }
            last = result
            DispatchQueue.main.async { [weak self] in
                guard let self, self.matches(current) else { return }
                self.onUpdate?(result)
            }
        }
        timer = source
        source.resume()
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        timer?.cancel(); timer = nil
        generation += 1
    }

    private func matches(_ value: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return timer != nil && value == generation
    }
}
