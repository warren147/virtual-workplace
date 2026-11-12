import Foundation

/// A read-only producer of session observations. Codex desktop IPC and the
/// Claude Code session registry both publish this renderer-independent shape.
protocol LiveSessionObserver: AnyObject {
    var onUpdate: ((CodexObservationResult) -> Void)? { get set }
    func start()
    func stop()
}

extension CodexDesktopObserver: LiveSessionObserver {}

/// Read-only desktop observations drive the same snapshot used by the saver.
/// Runtime idle is deliberately distinct from a confirmed successful turn.
final class CodexLiveTaskSource: TaskSource {
    private(set) var snapshot: SceneSnapshot
    private(set) var connectionMessage: String
    private(set) var isConnected = false
    private(set) var totalSessionCount = 0
    var onChange: (() -> Void)?
    private let observer: LiveSessionObserver
    let origin: WorkplaceTaskOrigin
    private var agent: String { origin.agentName }
    private var started = false
    private var records: [String: WorkplaceTask] = [:]
    private var completionEligible: Set<String> = []

    init(snapshot seed: SceneSnapshot = .empty(), observer: LiveSessionObserver = CodexDesktopObserver(),
         origin: WorkplaceTaskOrigin = .codex) {
        self.observer = observer
        self.origin = origin == .claude ? .claude : .codex
        connectionMessage = "正在连接 \(self.origin.agentName)…"
        var initial = SceneSnapshot.empty()
        initial.mode = seed.mode
        initial.preferredPosture = seed.preferredPosture
        if seed.taskOrigin == self.origin {
            initial.completedToday = seed.completedToday
            initial.summaryDay = seed.summaryDay
        }
        // Restored titles alone are not evidence that a task is still running.
        initial.taskOrigin = self.origin
        initial.sourceMessage = connectionMessage
        initial.isOnline = false
        initial.totalSessionCount = 0
        snapshot = initial
    }

    func start() {
        guard !started else { return }
        started = true
        observer.onUpdate = { [weak self] result in
            guard let self, self.started else { return }
            self.applyObservation(result, at: Date())
        }
        observer.start()
    }

    func stop() {
        started = false
        observer.stop()
        isConnected = false
        snapshot.isOnline = false
        snapshot.updatedAt = Date()
    }

    func tick(at now: Date) {
        normalizeDay(at: now)
        snapshot.updatedAt = now
        snapshot.isOnline = isConnected
    }

    func setMode(_ mode: EmployeeMode, at now: Date = Date()) {
        snapshot.mode = mode
        if mode == .standing { snapshot.preferredPosture = .standing }
        if mode == .sitting { snapshot.preferredPosture = .sitting }
        snapshot.updatedAt = now
        onChange?()
    }

    /// Kept separate from IO so mapping, stale state and overflow are testable
    /// using observations without touching the user's Codex installation.
    func applyObservation(_ result: CodexObservationResult, at now: Date) {
        normalizeDay(at: now)
        connectionMessage = String(result.message.prefix(240))
        isConnected = result.isConnected
        snapshot.taskOrigin = origin
        snapshot.sourceMessage = connectionMessage
        snapshot.updatedAt = now
        snapshot.isOnline = isConnected
        snapshot.demoRunning = false
        guard isConnected else {
            for index in snapshot.tasks.indices { snapshot.tasks[index].executionDetails = nil }
            for id in Array(records.keys) { records[id]?.executionDetails = nil }
            onChange?(); return
        }

        let observedIDs = Set(result.sessions.map(\.identity))
        records = records.filter { observedIDs.contains($0.key) }
        completionEligible.formIntersection(observedIDs)
        for session in result.sessions {
            let identity = session.identity
            let old = records[identity]
            let runtime = session.runtimeType
            let status: TaskStatus
            let step: String
            let next: String
            if runtime == "active" {
                completionEligible.insert(identity)
                let waiting = session.pendingRequest || session.activeFlags.contains {
                    ["waitingOnApproval", "waitingOnUserInput", "waitingForUserInput"].contains($0)
                }
                status = waiting ? .waiting : .running
                step = waiting ? "\(agent) 正在等你确认" : "\(agent) 正在执行任务"
                next = waiting ? "请在 \(agent) 会话中处理" : "实时同步会话状态"
            } else if runtime == "systemError" || session.turnStatus == "failed" {
                completionEligible.remove(identity)
                status = .failed
                step = "\(agent) 报告运行错误"
                next = "请在 \(agent) 会话中查看"
            } else if runtime == "idle", old != nil {
                // Idle only proves that execution stopped. Only an explicit
                // completed turn can increment the successful completion count.
                status = session.turnStatus == "completed" ? .completed : .idle
                step = status == .completed ? "本轮任务已完成" : "会话已待机"
                next = "等待下一项指令"
            } else {
                records.removeValue(forKey: identity)
                completionEligible.remove(identity)
                continue
            }
            if status == .completed, old?.status != .completed, completionEligible.remove(identity) != nil {
                snapshot.completedToday = min(1_000_000, (snapshot.completedToday ?? 0) + 1)
            }
            let title = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
            // A completed log from an earlier turn must not decorate a newly
            // active IPC session while its new task_started event is arriving.
            var details = session.executionDetails
            if status == .running || status == .waiting {
                if details?.phase == .idle { details = nil }
            } else if details != nil {
                details?.phase = .idle; details?.toolName = nil
            }
            let detailedStep: String
            if status == .running, let details {
                detailedStep = details.phase == .tool ? "调用工具 · \(details.toolName ?? agent)"
                    : details.phase == .thinking ? "\(agent) 正在思考" : step
            } else { detailedStep = step }
            records[identity] = WorkplaceTask(id: identity,
                title: String((title.isEmpty ? "\(agent) 会话" : title).prefix(160)), status: status,
                slot: old?.slot ?? -1, progress: nil, currentStep: String(detailedStep.prefix(160)),
                startedAt: details == nil ? nil : session.startedAt, nextStep: next, executionDetails: details,
                hostID: session.hostID, hostName: session.hostName)
        }

        totalSessionCount = records.count
        snapshot.totalSessionCount = totalSessionCount
        func rank(_ status: TaskStatus) -> Int {
            switch status {
            case .running: return 0
            case .waiting: return 1
            case .failed: return 2
            case .completed, .idle: return 3
            }
        }
        let previousSlots = Dictionary(uniqueKeysWithValues: snapshot.tasks.map { ($0.id, $0.slot) })
        var selected = Array(records.values.sorted {
            if rank($0.status) != rank($1.status) { return rank($0.status) < rank($1.status) }
            let a = previousSlots[$0.id] ?? 99, b = previousSlots[$1.id] ?? 99
            if a != b { return a < b }
            return $0.id < $1.id
        }.prefix(6))
        var used = Set(selected.compactMap { previousSlots[$0.id] })
        for index in selected.indices {
            if let slot = previousSlots[selected[index].id] { selected[index].slot = slot }
            else if let free = (0..<6).first(where: { !used.contains($0) }) {
                selected[index].slot = free
                used.insert(free)
            }
            records[selected[index].id]?.slot = selected[index].slot
        }
        snapshot.tasks = selected.sorted { $0.slot < $1.slot }
        let unfinished = records.values.contains { [.running, .waiting, .failed].contains($0.status) }
        if unfinished { snapshot.lastWorkEndedAt = nil }
        else if snapshot.lastWorkEndedAt == nil { snapshot.lastWorkEndedAt = now }
        onChange?()
    }

    private func normalizeDay(at now: Date) {
        let calendar = Calendar.autoupdatingCurrent
        if snapshot.summaryDay.map({ !calendar.isDate($0, inSameDayAs: now) }) ?? true {
            snapshot.summaryDay = calendar.startOfDay(for: now)
            snapshot.completedToday = 0
        }
    }
}
