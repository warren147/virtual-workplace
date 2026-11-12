import Foundation

enum EmployeeMode: String, Codable, CaseIterable {
    case automatic, sitting, slacking, standing
    var title: String {
        switch self {
        case .automatic: return "自动"
        case .sitting: return "坐着打工"
        case .slacking: return "摸鱼"
        case .standing: return "站着打工"
        }
    }
}

enum WorkPosture: String, Codable { case sitting, standing }
enum EmployeePose: String, Codable { case sitting, slacking, standing }
enum EmployeeActivity: String, Codable { case working, waiting, resting, offline }
enum WorkplaceTaskOrigin: String, Codable {
    case simulation, codex, claude
    /// Live origins mirror real sessions read-only; the simulator is editable.
    var isLive: Bool { self != .simulation }
    var agentName: String { self == .claude ? "Claude" : "Codex" }
}

enum WorkplaceBackground: String, Codable, CaseIterable {
    case room, outdoors
    var title: String { self == .room ? "房间" : "窗外" }
}

enum WorkplaceTheme: String, Codable, CaseIterable {
    case cabin, underwater

    var title: String { self == .cabin ? "原版小屋" : "海底工作站" }
    var notesTitle: String { self == .cabin ? "门外待办" : "海中待办" }

    func title(for background: WorkplaceBackground) -> String {
        guard self == .underwater else { return background.title }
        return background == .room ? "浅海" : "深海"
    }

    func title(for action: EmployeeAction) -> String {
        guard self == .underwater else { return action.title }
        switch action {
        case .coffee: return "吐气泡"
        case .stretch: return "水中翻身"
        case .wave: return "挥挥手"
        case .playWithCat: return "陪海豹玩"
        case .walk: return "潜游一圈"
        }
    }

    func title(for weather: WorldWeather) -> String {
        guard self == .underwater else { return weather.title }
        switch weather {
        case .clear: return "清澈水域"
        case .cloudy: return "轻度浑浊"
        case .rain: return "活跃海流"
        case .snow: return "海洋雪"
        case .thunderstorm: return "强海流"
        }
    }

    func title(for light: WorldTimeMode) -> String {
        guard self == .underwater else { return light.title }
        switch light {
        case .automatic: return "随自然光变化"
        case .day: return "明亮透光"
        case .sunset: return "柔和散光"
        case .night: return "微光"
        }
    }
}

enum SceneDisplayContext: String, Codable, CaseIterable {
    case desktop, screenSaver
    var title: String { self == .desktop ? "桌面背景" : "系统屏保" }
}

enum WorldWeather: String, Codable, CaseIterable {
    case clear, cloudy, rain, snow, thunderstorm
    var title: String {
        switch self {
        case .clear: return "晴天"
        case .cloudy: return "多云"
        case .rain: return "下雨"
        case .snow: return "下雪"
        case .thunderstorm: return "雷雨"
        }
    }
}

enum WeatherMode: String, Codable, CaseIterable {
    case random, manual
    var title: String { self == .random ? "随机天气" : "固定天气" }
}

enum WorldTimeMode: String, Codable, CaseIterable {
    case automatic, day, sunset, night
    var title: String {
        switch self {
        case .automatic: return "跟随本机时间"
        case .day: return "白天"
        case .sunset: return "黄昏"
        case .night: return "夜晚"
        }
    }
}

struct WorldEnvironment: Equatable {
    var daylight: Double
    var sunset: Double
    var darkness: Double
    var title: String
}

enum SceneWorldError: Error, LocalizedError {
    case invalidDisplays, invalidPendingWeather
    var errorDescription: String? {
        switch self {
        case .invalidDisplays: return "屏幕背景设置不合法"
        case .invalidPendingWeather: return "待办天气节奏不合法"
        }
    }
}

/// Every display and the saver receive one world definition. Its lighting is
/// derived from a shared absolute date rather than a per-view animation clock.
struct SceneWorld: Codable, Equatable {
    var theme: WorkplaceTheme = .cabin
    var weather: WorldWeather = .clear
    var weatherMode: WeatherMode = .random
    var timeMode: WorldTimeMode = .automatic
    /// Existing choices remain desktop preferences when older files are read.
    var displayScenes: [String: WorkplaceBackground] = [:]
    var screenSaverDisplayScenes: [String: WorkplaceBackground] = [:]
    // Retained for decoding older preference files. Notes no longer drive
    // weather; all hosts resolve weatherMode from the same absolute clock.
    var pendingWeatherEnabled: Bool = true
    var pendingWeatherPace: PendingWeatherPace = .balanced

    init(weather: WorldWeather = .clear, weatherMode: WeatherMode = .random,
         timeMode: WorldTimeMode = .automatic,
         displayScenes: [String: WorkplaceBackground] = [:],
         screenSaverDisplayScenes: [String: WorkplaceBackground] = [:],
         pendingWeatherEnabled: Bool = true, pendingWeatherPace: PendingWeatherPace = .balanced,
         theme: WorkplaceTheme = .cabin) {
        self.theme = theme
        self.weather = weather; self.weatherMode = weatherMode
        self.timeMode = timeMode; self.displayScenes = displayScenes
        self.screenSaverDisplayScenes = screenSaverDisplayScenes
        self.pendingWeatherEnabled = pendingWeatherEnabled; self.pendingWeatherPace = pendingWeatherPace
    }

    private enum CodingKeys: String, CodingKey {
        case theme, weather, weatherMode, timeMode, displayScenes, screenSaverDisplayScenes, pendingWeatherEnabled, pendingWeatherPace
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        theme = try values.decodeIfPresent(WorkplaceTheme.self, forKey: .theme) ?? .cabin
        weather = try values.decodeIfPresent(WorldWeather.self, forKey: .weather) ?? .clear
        // Upgrades opt into the new independent weather even if an older
        // pending-note policy was enabled. Preserve the stored manual choice.
        weatherMode = try values.decodeIfPresent(WeatherMode.self, forKey: .weatherMode) ?? .random
        timeMode = try values.decodeIfPresent(WorldTimeMode.self, forKey: .timeMode) ?? .automatic
        displayScenes = try values.decodeIfPresent([String: WorkplaceBackground].self, forKey: .displayScenes) ?? [:]
        screenSaverDisplayScenes = try values.decodeIfPresent([String: WorkplaceBackground].self, forKey: .screenSaverDisplayScenes) ?? [:]
        pendingWeatherEnabled = try values.decodeIfPresent(Bool.self, forKey:.pendingWeatherEnabled) ?? true
        pendingWeatherPace = try values.decodeIfPresent(PendingWeatherPace.self, forKey:.pendingWeatherPace) ?? .balanced
    }

    func displayScenes(for context: SceneDisplayContext) -> [String: WorkplaceBackground] {
        context == .desktop ? displayScenes : screenSaverDisplayScenes
    }

    mutating func setDisplayScenes(_ scenes: [String: WorkplaceBackground], for context: SceneDisplayContext) {
        switch context {
        case .desktop: displayScenes = scenes
        case .screenSaver: screenSaverDisplayScenes = scenes
        }
    }

    func validate() throws {
        guard pendingWeatherPace.cloudyAfter.isFinite, pendingWeatherPace.rainAfter.isFinite,
              pendingWeatherPace.stormAfter.isFinite, pendingWeatherPace.cloudyAfter > 0,
              pendingWeatherPace.cloudyAfter < pendingWeatherPace.rainAfter,
              pendingWeatherPace.rainAfter < pendingWeatherPace.stormAfter else {
            throw SceneWorldError.invalidPendingWeather
        }
        for context in SceneDisplayContext.allCases {
            let scenes = displayScenes(for: context)
            guard scenes.count <= 32, scenes.keys.allSatisfy({ id in
                !id.isEmpty && id.utf8.count <= 128
                    && id == id.trimmingCharacters(in: .whitespacesAndNewlines)
                    && !id.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            }) else { throw SceneWorldError.invalidDisplays }
        }
    }

    func environment(at date: Date, calendar: Calendar = .autoupdatingCurrent) -> WorldEnvironment {
        switch timeMode {
        case .day: return WorldEnvironment(daylight: 1, sunset: 0, darkness: 0, title: "白天")
        case .sunset: return WorldEnvironment(daylight: 0.45, sunset: 1, darkness: 0.55, title: "黄昏")
        case .night: return WorldEnvironment(daylight: 0, sunset: 0, darkness: 1, title: "夜晚")
        case .automatic: break
        }
        guard date.timeIntervalSinceReferenceDate.isFinite else {
            return WorldEnvironment(daylight: 1, sunset: 0, darkness: 0, title: "白天")
        }
        let parts = calendar.dateComponents([.hour, .minute, .second], from: date)
        let hour = Double(parts.hour ?? 12) + Double(parts.minute ?? 0) / 60 + Double(parts.second ?? 0) / 3600
        func smooth(_ value: Double) -> Double { let t = min(1, max(0, value)); return t * t * (3 - 2 * t) }
        if hour >= 6 && hour < 8 {
            let t = (hour - 6) / 2
            let day = smooth(t)
            return WorldEnvironment(daylight: day, sunset: sin(t * .pi) * 0.35,
                                    darkness: 1 - day, title: "清晨")
        }
        if hour >= 8 && hour < 17 {
            return WorldEnvironment(daylight: 1, sunset: 0, darkness: 0, title: "白天")
        }
        if hour >= 17 && hour < 20 {
            let t = (hour - 17) / 3
            let day = 1 - smooth(t)
            return WorldEnvironment(daylight: day, sunset: sin(t * .pi), darkness: 1 - day, title: "黄昏")
        }
        return WorldEnvironment(daylight: 0, sunset: 0, darkness: 1, title: "夜晚")
    }
}

enum EmployeeAction: String, Codable, CaseIterable {
    case coffee, stretch, wave, playWithCat, walk
    var title: String {
        switch self {
        case .coffee: return "喝咖啡"
        case .stretch: return "伸懒腰"
        case .wave: return "挥挥手"
        case .playWithCat: return "逗逗猫"
        case .walk: return "溜达一圈"
        }
    }
    var duration: TimeInterval {
        switch self {
        case .coffee: return 5.5
        case .stretch: return 5
        case .wave: return 4.5
        case .playWithCat: return 12
        case .walk: return 20
        }
    }
}

struct SceneAction: Codable, Equatable, Identifiable {
    var id: String = UUID().uuidString
    var kind: EmployeeAction
    var startedAt: Date
    func isActive(at now: Date = Date()) -> Bool {
        let elapsed = now.timeIntervalSince(startedAt)
        return elapsed >= 0 && elapsed < kind.duration
    }
    func progress(at now: Date = Date()) -> Double {
        min(1, max(0, now.timeIntervalSince(startedAt) / kind.duration))
    }
}

enum TaskStatus: String, Codable, CaseIterable {
    case running, waiting, completed, failed, idle
    var title: String {
        switch self {
        case .running: return "工作中"
        case .waiting: return "等待确认"
        case .completed: return "已完成"
        case .failed: return "出错了"
        case .idle: return "待机"
        }
    }
}

enum CodexExecutionPhase: String, Codable { case thinking, tool, working, idle }

/// Bounded, user-visible metadata from the same local events used by Island.
/// Arguments, tool output and reasoning content never enter this model.
struct CodexExecutionDetails: Codable, Equatable {
    var phase: CodexExecutionPhase
    var latestUpdate: String? = nil
    var toolName: String? = nil
    var updatedAt: Date
    var turnID: String? = nil
}

struct WorkplaceTask: Codable, Equatable, Identifiable {
    var id: String
    var title: String
    var status: TaskStatus
    var slot: Int
    /// Optional so snapshots written by 0.1 remain readable without inventing progress.
    var progress: Double? = nil
    var currentStep: String? = nil
    var startedAt: Date? = nil
    var nextStep: String? = nil
    var executionDetails: CodexExecutionDetails? = nil
    /// Absent in older snapshots and local simulations. Keep the original
    /// thread title separate from the machine that is running it.
    var hostID: String? = nil
    var hostName: String? = nil

    var sourceLabel: String {
        if let name = hostName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        return hostID.map { $0.isEmpty || $0 == "local" ? "本机" : "开发机" } ?? "本机"
    }

    var activityTitle: String {
        guard status == .running else { return status.title }
        switch executionDetails?.phase {
        case .thinking: return "思考中"
        case .tool: return "调用工具"
        case .working, .idle, nil: return status.title
        }
    }
}

struct SceneSnapshot: Codable, Equatable {
    var schemaVersion: Int = 1
    var mode: EmployeeMode
    var preferredPosture: WorkPosture
    var tasks: [WorkplaceTask]
    var updatedAt: Date
    /// Start of the all-finished grace period. Waiting or failed tasks are not finished.
    var lastWorkEndedAt: Date?
    var isOnline: Bool
    var demoRunning: Bool
    /// Counts completion transitions, including a reopened task completing again.
    /// Closing a session does not remove its completion from this daily total.
    var completedToday: Int? = nil
    var summaryDay: Date? = nil
    /// Nil in older snapshots means the original simulator.
    var taskOrigin: WorkplaceTaskOrigin? = nil
    var sourceMessage: String? = nil
    var totalSessionCount: Int? = nil
    var action: SceneAction? = nil
    /// Missing in earlier snapshots; hosts then use the original room defaults.
    var world: SceneWorld? = nil
    /// Personal notes never occupy a Codex task slot or drive employee posture.
    /// Optional so snapshots from before notes were introduced remain readable.
    var pendingNotes: [PendingNote]? = nil

    static func empty(now: Date = Date()) -> SceneSnapshot {
        SceneSnapshot(mode: .automatic, preferredPosture: .sitting, tasks: [],
                      updatedAt: now, lastWorkEndedAt: nil, isOnline: true, demoRunning: false,
                      completedToday: 0, summaryDay: Calendar.autoupdatingCurrent.startOfDay(for: now))
    }

    func isFresh(at now: Date = Date()) -> Bool {
        let age = now.timeIntervalSince(updatedAt)
        return isOnline && age <= 10 && age >= -5
    }

    func resolvedPose(at now: Date = Date()) -> EmployeePose {
        guard isFresh(at: now) else { return .slacking }
        switch mode {
        case .sitting: return .sitting
        case .slacking: return .slacking
        case .standing: return .standing
        case .automatic:
            let unfinished = tasks.contains { [.running, .waiting, .failed].contains($0.status) }
            let grace = lastWorkEndedAt.map { now.timeIntervalSince($0) < 10 } ?? false
            guard unfinished || grace else { return .slacking }
            return preferredPosture == .standing ? .standing : .sitting
        }
    }

    func resolvedActivity(at now: Date = Date()) -> EmployeeActivity {
        guard isFresh(at: now) else { return .offline }
        if resolvedPose(at: now) == .slacking { return .resting }
        if tasks.contains(where: { $0.status == .running }) { return .working }
        if tasks.contains(where: { $0.status == .waiting || $0.status == .failed }) { return .waiting }
        return mode == .automatic ? .resting : .working
    }
}

/// Simulated and live desktop sources publish the same renderer-independent snapshot.
protocol TaskSource: AnyObject {
    var snapshot: SceneSnapshot { get }
    func tick(at: Date)
}

final class TaskSimulator: TaskSource {
    private(set) var snapshot: SceneSnapshot
    private var demoStart: Date?
    private var demoCycle = -1
    private var appliedDemoStep = -1
    private var sequence = 0
    private var progress = 0.0
    var demoProgress: Double { progress }

    init(snapshot: SceneSnapshot = .empty()) {
        self.snapshot = snapshot
        // A demo clock belongs to this process, never to a restored state file.
        self.snapshot.demoRunning = false
    }

    func setMode(_ mode: EmployeeMode, at now: Date = Date()) {
        stopDemo()
        snapshot.mode = mode
        if mode == .standing { snapshot.preferredPosture = .standing }
        if mode == .sitting { snapshot.preferredPosture = .sitting }
        touch(at: now)
    }

    func addTask(at now: Date = Date()) {
        stopDemo()
        guard snapshot.tasks.count < 6 else { return }
        let used = Set(snapshot.tasks.map(\.slot))
        guard let slot = (0..<6).first(where: { !used.contains($0) }) else { return }
        sequence += 1
        let titles = ["搭建应用界面", "实现任务状态", "整理项目文件", "检查动画效果", "运行本地测试", "完善屏保体验"]
        snapshot.tasks.append(makeTask(id: UUID().uuidString, title: titles[(sequence - 1) % titles.count],
                                      slot: slot, at: now))
        refreshIdle(at: now)
        touch(at: now)
    }

    func removeTask(id: String, at now: Date = Date()) {
        stopDemo()
        guard snapshot.tasks.contains(where: { $0.id == id }) else { return }
        snapshot.tasks.removeAll { $0.id == id }
        refreshIdle(at: now)
        touch(at: now)
    }

    func setTaskStatus(id: String, status: TaskStatus, at now: Date = Date()) {
        stopDemo()
        guard let index = snapshot.tasks.firstIndex(where: { $0.id == id }) else { return }
        transitionTask(at: index, to: status, date: now)
        refreshIdle(at: now)
        touch(at: now)
    }

    func setDemoRunning(_ running: Bool, at now: Date = Date()) {
        guard running else { stopDemo(); touch(at: now); return }
        demoStart = now
        demoCycle = -1
        appliedDemoStep = -1
        progress = 0
        snapshot.demoRunning = true
        tick(at: now)
    }

    func tick(at now: Date = Date()) {
        normalizeSummaryDay(at: now)
        if snapshot.demoRunning, let start = demoStart {
            let elapsed = max(0, now.timeIntervalSince(start))
            let cycle = Int(elapsed / 60)
            let seconds = elapsed.truncatingRemainder(dividingBy: 60)
            progress = seconds / 60
            if cycle != demoCycle {
                demoCycle = cycle
                appliedDemoStep = -1
                let completed = snapshot.completedToday
                let summaryDay = snapshot.summaryDay
                snapshot = .empty(now: now)
                snapshot.completedToday = completed
                snapshot.summaryDay = summaryDay
                snapshot.demoRunning = true
            }
            let boundaries: [Double] = [0, 6, 12, 18, 24, 30, 36, 40, 44, 48]
            for (step, boundary) in boundaries.enumerated() where step > appliedDemoStep && seconds >= boundary {
                applyDemoStep(step, at: start.addingTimeInterval(Double(cycle) * 60 + boundary))
                appliedDemoStep = step
            }
        }
        updateTaskProgress(at: now)
        snapshot.updatedAt = now
        snapshot.isOnline = true
    }

    func markOffline(at now: Date = Date()) {
        stopDemo()
        snapshot.isOnline = false
        normalizeSummaryDay(at: now)
        snapshot.updatedAt = now
    }

    private func stopDemo() {
        snapshot.demoRunning = false
        demoStart = nil
        progress = 0
    }

    private func touch(at now: Date) {
        normalizeSummaryDay(at: now)
        snapshot.updatedAt = now
        snapshot.isOnline = true
    }

    private func normalizeSummaryDay(at now: Date) {
        let calendar = Calendar.autoupdatingCurrent
        let day = calendar.startOfDay(for: now)
        if snapshot.summaryDay.map({ !calendar.isDate($0, inSameDayAs: now) }) ?? true {
            snapshot.summaryDay = day
            snapshot.completedToday = 0
        } else if snapshot.completedToday == nil {
            snapshot.completedToday = 0
        }
    }

    private func makeTask(id: String, title: String, slot: Int, at now: Date) -> WorkplaceTask {
        WorkplaceTask(id: id, title: title, status: .running, slot: slot,
                      progress: 0, currentStep: "准备模拟任务", startedAt: now, nextStep: "执行当前步骤")
    }

    private func transitionTask(at index: Int, to status: TaskStatus, date now: Date) {
        normalizeSummaryDay(at: now)
        let previous = snapshot.tasks[index].status
        snapshot.tasks[index].status = status
        if status == .completed && previous != .completed {
            snapshot.completedToday = min(1_000_000, (snapshot.completedToday ?? 0) + 1)
        }
        switch status {
        case .completed:
            snapshot.tasks[index].progress = 1
            snapshot.tasks[index].currentStep = "任务已完成"
            snapshot.tasks[index].nextStep = "等待下一项任务"
        case .waiting:
            snapshot.tasks[index].currentStep = "等待你确认"
            snapshot.tasks[index].nextStep = "在会话中处理确认事项"
        case .failed:
            snapshot.tasks[index].currentStep = "任务遇到问题"
            snapshot.tasks[index].nextStep = "检查会话并重新运行"
        case .idle:
            snapshot.tasks[index].progress = nil
            snapshot.tasks[index].currentStep = "本轮已结束"
            snapshot.tasks[index].nextStep = "等待下一项指令"
        case .running:
            if previous == .completed {
                snapshot.tasks[index].startedAt = now
                snapshot.tasks[index].progress = 0
            }
            snapshot.tasks[index].currentStep = "执行模拟步骤"
            snapshot.tasks[index].nextStep = "检查模拟结果"
        }
    }

    private func updateTaskProgress(at now: Date) {
        let steps = ["准备模拟任务", "执行当前步骤", "检查模拟结果", "整理任务输出"]
        let nextSteps = ["执行当前步骤", "检查模拟结果", "整理任务输出", "等待任务完成"]
        for index in snapshot.tasks.indices where snapshot.tasks[index].status == .running {
            // A legacy or external source with unknown timing keeps unknown progress.
            guard let start = snapshot.tasks[index].startedAt else { continue }
            let duration = 80.0 + Double(snapshot.tasks[index].slot) * 15.0
            let value = min(0.95, max(0, now.timeIntervalSince(start) / duration))
            snapshot.tasks[index].progress = value
            let step = min(3, Int(value * 4))
            snapshot.tasks[index].currentStep = steps[step]
            snapshot.tasks[index].nextStep = nextSteps[step]
        }
    }

    private func refreshIdle(at now: Date) {
        if snapshot.tasks.contains(where: { [.running, .waiting, .failed].contains($0.status) }) {
            snapshot.lastWorkEndedAt = nil
        } else if snapshot.lastWorkEndedAt == nil {
            snapshot.lastWorkEndedAt = now
        }
    }

    private func applyDemoStep(_ step: Int, at now: Date) {
        func add(_ slot: Int) {
            let titles = ["搭建应用界面", "实现任务状态", "整理项目文件", "检查动画效果", "运行本地测试", "完善屏保体验"]
            snapshot.tasks.append(makeTask(id: "demo-\(demoCycle)-\(slot)", title: titles[slot], slot: slot, at: now))
        }
        switch step {
        case 0: add(0)
        case 1: add(1)
        case 2: add(2)
        case 3: (3..<6).forEach { add($0) }
        case 4: snapshot.preferredPosture = .standing
        case 5:
            for index in snapshot.tasks.indices { transitionTask(at: index, to: index == 0 ? .failed : .waiting, date: now) }
        case 6:
            for index in snapshot.tasks.indices { transitionTask(at: index, to: .completed, date: now) }
        case 7: snapshot.tasks.removeAll { $0.slot >= 3 }
        case 8: snapshot.tasks.removeAll { $0.slot >= 1 }
        case 9: snapshot.tasks.removeAll()
        default: break
        }
        refreshIdle(at: now)
    }
}
