import AppKit

private enum AppPalette {
    static let paper = NSColor(srgbRed: 0.96, green: 0.95, blue: 0.92, alpha: 1)
    static let panel = NSColor(srgbRed: 0.99, green: 0.98, blue: 0.96, alpha: 1)
    static let ink = NSColor(srgbRed: 0.17, green: 0.23, blue: 0.22, alpha: 1)
    static let secondary = NSColor(srgbRed: 0.45, green: 0.49, blue: 0.45, alpha: 1)
    static let green = NSColor(srgbRed: 0.28, green: 0.43, blue: 0.36, alpha: 1)
    static let waiting = NSColor(srgbRed: 0.20, green: 0.40, blue: 0.65, alpha: 1)
    static let line = NSColor(srgbRed: 0.86, green: 0.87, blue: 0.82, alpha: 1)
}

final class ActionButton: NSButton {
    var actionHandler: (() -> Void)?
    convenience init(_ title: String, symbol: String? = nil, action: @escaping () -> Void) {
        self.init(title: title, target: nil, action: nil)
        bezelStyle = .rounded
        font = .systemFont(ofSize: 12, weight: .medium)
        if let symbol = symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: title); imagePosition = .imageLeading }
        target = self
        self.action = #selector(invoke)
        actionHandler = action
    }
    @objc private func invoke() { actionHandler?() }
}

final class TaskStatusPopup: NSPopUpButton {
    var actionHandler: ((Int) -> Void)?
    override init(frame buttonFrame: NSRect, pullsDown flag: Bool) {
        super.init(frame: buttonFrame, pullsDown: flag)
        target = self
        action = #selector(changed)
        controlSize = .small
        font = .systemFont(ofSize: 11)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func changed() { actionHandler?(indexOfSelectedItem) }
}

final class TaskListStack: NSStackView {
    override var isFlipped: Bool { true }
}

final class WorkplaceAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let store: StateStore
    private let stateURL: URL
    private let worldStore: WorldSettingsStore
    private var notesInbox: PendingNoteInbox?
    private let notesPanel = PendingNotesPanelController()
    private let quickNoteHotKey = QuickNoteHotKey()
    private var notesError: String?
    private var notesButton: ActionButton?
    private var notesMenuItems: [NSMenuItem] = []
    private var world = SceneWorld()
    private var worldSettingsError: String?
    private let sceneSettings = ScreenSceneSettingsController()
    private var displaySettingsObserver: NSObjectProtocol?
    private let launchDemo: Bool
    private let launchWallpaper: Bool
    private let presentation = ScenePresentationController()
    private var simulator: TaskSimulator!
    private var codexSource: CodexLiveTaskSource?
    private var claudeSource: CodexLiveTaskSource?
    private var liveOrigin: WorkplaceTaskOrigin = .codex
    private var liveSource: CodexLiveTaskSource? { liveOrigin == .claude ? claudeSource : codexSource }
    private var liveAgent: String { liveOrigin.agentName }
    private var usesLiveSource = true
    private var sourcePicker: NSSegmentedControl!
    private var sourceHint: NSTextField!
    private var sourceFootnote: NSTextField!
    private var sourceMenuTitle: NSMenuItem?
    private var window: NSWindow!
    private var scene: WorkplaceSceneView!
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var modePicker: NSSegmentedControl!
    private var taskList: NSStackView!
    private var taskCount: NSTextField!
    private var activityLabel: NSTextField!
    private var syncLabel: NSTextField!
    private var demoButton: ActionButton!
    private var demoProgress: NSProgressIndicator!
    private var addButton: ActionButton!
    private var sceneContainer: NSView!
    private var sidebarContainer: NSView!
    private var taskScrollView: NSScrollView!
    private var previousTasks: [WorkplaceTask] = []
    private var previousSourceConnected: Bool?
    private var hasBuiltTasks = false
    private var lastWriteError: String?
    private var wallpaperButton: ActionButton!
    private var wallpaperMenuItems: [NSMenuItem] = []
    private var screenSaverInstallButton: ActionButton?
    private var isInstallingScreenSaver = false
    private var currentAction: SceneAction?
    private let ambientMotion = AmbientEmployeeMotion()
    private var ambientActionsEnabled = false
    private var actionButtons: [EmployeeAction: ActionButton] = [:]
    private var walkMenuItem: NSMenuItem?
    private var actionStatusLabel: NSTextField!
    private var stopActionButton: ActionButton!

    init(stateURL: URL?, launchDemo: Bool, launchWallpaper: Bool = false) {
        self.stateURL = stateURL ?? StateStore.defaultURL
        store = StateStore(url: self.stateURL)
        worldStore = WorldSettingsStore(url: self.stateURL.deletingLastPathComponent().appendingPathComponent("world-settings.json"))
        self.launchDemo = launchDemo
        self.launchWallpaper = launchWallpaper
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let restored = (try? store.read()) ?? .empty()
        notesInbox = PendingNoteInbox(store: PendingNoteStore(url: stateURL.deletingLastPathComponent()
            .appendingPathComponent("pending-notes.json")), fallback: restored.pendingNotes ?? [])
        notesError = notesInbox?.loadError
        notesPanel.onAdd = { [weak self] text in self?.addPendingNote(text) }
        notesPanel.onRemove = { [weak self] id in self?.removePendingNote(id) }
        notesPanel.onUndo = { [weak self] in self?.undoPendingNoteRemoval() }
        world = (try? worldStore.read()) ?? restored.world ?? SceneWorld()
        establishDisplayDefaults()
        sceneSettings.onChange = { [weak self] value in self?.saveWorld(value) }
        displaySettingsObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.establishDisplayDefaults()
            self.sceneSettings.update(snapshot: self.currentSnapshot)
            self.update()
        }
        var simulationSeed = restored
        // A live task must never become an editable, simulated copy after restart.
        if restored.taskOrigin?.isLive == true {
            simulationSeed = .empty()
            simulationSeed.mode = restored.mode
            simulationSeed.preferredPosture = restored.preferredPosture
        }
        simulationSeed.taskOrigin = .simulation
        simulationSeed.sourceMessage = nil
        simulationSeed.totalSessionCount = nil
        simulator = TaskSimulator(snapshot: simulationSeed)
        simulator.tick()
        usesLiveSource = !launchDemo
        liveOrigin = restored.taskOrigin == .claude ? .claude : .codex
        codexSource = CodexLiveTaskSource(snapshot: restored)
        claudeSource = CodexLiveTaskSource(snapshot: restored, observer: ClaudeSessionObserver(), origin: .claude)
        if launchDemo { simulator.setDemoRunning(true) }
        buildMenu()
        buildWindow()
        buildStatusItem()
        quickNoteHotKey.start { [weak self] in self?.openPendingNotes() }
        notesPanel.setQuickCaptureShortcutAvailable(quickNoteHotKey.isRegistered)
        presentation.onExitImmersive = { [weak self] in self?.openWindow() }
        presentation.onWallpaperChanged = { [weak self] enabled in self?.refreshWallpaperControls(enabled: enabled) }
        ambientActionsEnabled = true
        for source in [codexSource, claudeSource] {
            source?.onChange = { [weak self, weak source] in
                guard let self = self, self.usesLiveSource, source === self.liveSource else { return }
                self.update()
            }
        }
        update()
        if usesLiveSource { liveSource?.start() }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if self.usesLiveSource { self.liveSource?.tick(at: Date()) }
            else { self.simulator.tick() }
            self.update()
        }
        RunLoop.main.add(timer!, forMode: .common)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.screensDidSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(didWake), name: NSWorkspace.screensDidWakeNotification, object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(openWindow), name: Notification.Name("local.virtualworkplace.openWindow"), object: stateURL.path)
        openWindow()
        if launchWallpaper { presentation.setWallpaperEnabled(true) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Activation or a Dock reopen must not put the main room in front of
        // a quick capture that has already brought its editor on screen.
        if notesPanel.window?.isVisible == true { openPendingNotes() }
        else { openWindow() }
        return false
    }
    func applicationWillTerminate(_ notification: Notification) {
        quickNoteHotKey.stop()
        if let displaySettingsObserver { NotificationCenter.default.removeObserver(displaySettingsObserver) }
        sceneSettings.close()
        notesPanel.close()
        timer?.invalidate()
        scene?.stopAnimating()
        presentation.closeAll()
        currentAction = nil
        liveSource?.stop()
        simulator?.markOffline()
        if simulator != nil {
            var final = currentSnapshot
            final.isOnline = false
            final.demoRunning = false
            final.updatedAt = Date()
            try? store.write(final)
        }
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
    }

    private func buildMenu() {
        let mainMenu = NSMenu()
        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu()
        applicationMenu.addItem(withTitle: "关于虚拟工位", action: #selector(showAbout), keyEquivalent: "").target = self
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(withTitle: "隐藏虚拟工位", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h").target = NSApp
        applicationMenu.addItem(withTitle: "退出虚拟工位", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q").target = NSApp
        applicationItem.submenu = applicationMenu
        mainMenu.addItem(applicationItem)
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)
        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "显示")
        viewMenu.addItem(withTitle: "打开工位", action: #selector(openWindow), keyEquivalent: "1").target = self
        let inboxItem = viewMenu.addItem(withTitle: "门外待办", action: #selector(openPendingNotes), keyEquivalent: "2")
        inboxItem.target = self
        notesMenuItems.append(inboxItem)
        let captureItem = viewMenu.addItem(withTitle: "快速记录待办", action: #selector(openPendingNotes), keyEquivalent: "n")
        captureItem.keyEquivalentModifierMask = [.control, .option, .command]
        captureItem.target = self
        viewMenu.addItem(withTitle: "进入全屏", action: #selector(toggleFullScreen), keyEquivalent: "f").target = self
        viewMenu.addItem(withTitle: "屏幕场景与环境…", action: #selector(openSceneSettings), keyEquivalent: ",").target = self
        let wallpaperItem = viewMenu.addItem(withTitle: "设为桌面背景", action: #selector(toggleWallpaper), keyEquivalent: "")
        wallpaperItem.target = self
        wallpaperMenuItems.append(wallpaperItem)
        viewMenu.addItem(.separator())
        let walk = viewMenu.addItem(withTitle: "溜达一圈", action: #selector(takeWalk), keyEquivalent: "")
        walk.target = self
        walkMenuItem = walk
        viewMenu.addItem(withTitle: "安装系统屏保…", action: #selector(installScreenSaver), keyEquivalent: "").target = self
        viewMenu.addItem(withTitle: "打开壁纸与屏保设置", action: #selector(openScreenSaverSettings), keyEquivalent: "").target = self
        viewItem.submenu = viewMenu
        mainMenu.addItem(viewItem)
        NSApp.mainMenu = mainMenu
    }

    private func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 820),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.title = "虚拟工位"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = AppPalette.paper
        window.appearance = NSAppearance(named: .aqua)
        window.minSize = NSSize(width: 960, height: 640)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = AppPalette.paper.cgColor
        window.contentView = root

        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 10
        let title = label("虚拟工位", size: 24, weight: .semibold)
        let version = label("PIXEL WORKPLACE  0.9.4", size: 10, weight: .semibold, color: AppPalette.secondary)
        let titleGroup = NSStackView(views: [title, version])
        titleGroup.orientation = .vertical
        titleGroup.alignment = .leading
        titleGroup.spacing = 3
        header.addArrangedSubview(titleGroup)
        header.addArrangedSubview(spacer())
        syncLabel = label("● 本地同步", size: 11, weight: .medium, color: AppPalette.green)
        header.addArrangedSubview(syncLabel)
        let inboxButton = ActionButton("门外待办", symbol: "text.bubble") { [weak self] in self?.openPendingNotes() }
        inboxButton.toolTip = "写一条 note，来一位门外等候的访客"
        notesButton = inboxButton
        header.addArrangedSubview(inboxButton)
        wallpaperButton = ActionButton("桌面背景", symbol: "desktopcomputer") { [weak self] in self?.toggleWallpaper() }
        header.addArrangedSubview(wallpaperButton)
        header.addArrangedSubview(ActionButton("屏幕场景", symbol: "display.2") { [weak self] in self?.openSceneSettings() })
        let installButton = ActionButton("安装屏保", symbol: "sparkles.tv") { [weak self] in self?.installScreenSaver() }
        installButton.toolTip = "安装或更新系统屏保，然后在系统设置中选择 VirtualWorkplace"
        screenSaverInstallButton = installButton
        header.addArrangedSubview(installButton)
        header.addArrangedSubview(ActionButton("全屏", symbol: "arrow.up.left.and.arrow.down.right") { [weak self] in self?.toggleFullScreen() })

        scene = WorkplaceSceneView(frame: .zero)
        scene.wantsLayer = true
        scene.layer?.cornerRadius = 18
        scene.layer?.masksToBounds = true
        scene.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let sceneWrap = NSView()
        sceneContainer = sceneWrap
        sceneWrap.wantsLayer = true
        sceneWrap.layer?.backgroundColor = AppPalette.panel.cgColor
        sceneWrap.layer?.cornerRadius = 18
        scene.translatesAutoresizingMaskIntoConstraints = false
        sceneWrap.addSubview(scene)
        NSLayoutConstraint.activate([
            scene.leadingAnchor.constraint(equalTo: sceneWrap.leadingAnchor),
            scene.trailingAnchor.constraint(equalTo: sceneWrap.trailingAnchor),
            scene.topAnchor.constraint(equalTo: sceneWrap.topAnchor),
            scene.bottomAnchor.constraint(equalTo: sceneWrap.bottomAnchor)
        ])

        let sidebar = NSStackView()
        sidebarContainer = sidebar
        sidebar.orientation = .vertical
        sidebar.alignment = .leading
        sidebar.spacing = 12
        sidebar.edgeInsets = NSEdgeInsets(top: 20, left: 18, bottom: 18, right: 18)
        sidebar.wantsLayer = true
        sidebar.layer?.backgroundColor = AppPalette.panel.cgColor
        sidebar.layer?.cornerRadius = 18
        sidebar.widthAnchor.constraint(equalToConstant: 250).isActive = true
        let sideTitle = label("正在发生", size: 17, weight: .semibold)
        sidebar.addArrangedSubview(sideTitle)
        let sourceGroup = NSStackView()
        sourceGroup.orientation = .vertical
        sourceGroup.alignment = .leading
        sourceGroup.spacing = 6
        sourcePicker = NSSegmentedControl(labels: ["Codex", "Claude", "模拟"], trackingMode: .selectOne, target: self, action: #selector(sourceChanged))
        sourcePicker.segmentStyle = .rounded
        sourcePicker.setWidth(70, forSegment: 0)
        sourcePicker.setWidth(70, forSegment: 1)
        sourcePicker.setWidth(62, forSegment: 2)
        sourcePicker.setAccessibilityLabel("任务来源")
        sourceGroup.addArrangedSubview(sourcePicker)
        sourceHint = label("基础三屏，随任务扩展。", size: 11, color: AppPalette.secondary)
        sourceHint.maximumNumberOfLines = 2
        sourceHint.widthAnchor.constraint(equalToConstant: 212).isActive = true
        sourceGroup.addArrangedSubview(sourceHint)
        sidebar.addArrangedSubview(sourceGroup)
        let separator = NSBox()
        separator.boxType = .separator
        separator.widthAnchor.constraint(equalToConstant: 210).isActive = true
        sidebar.addArrangedSubview(separator)
        let countRow = NSStackView()
        countRow.orientation = .horizontal
        taskCount = label("会话  0 / 6", size: 11, weight: .medium, color: AppPalette.secondary)
        countRow.addArrangedSubview(taskCount)
        countRow.addArrangedSubview(spacer())
        addButton = ActionButton("添加", symbol: "plus") { [weak self] in self?.mutate { $0.addTask() } }
        addButton.controlSize = .small
        countRow.addArrangedSubview(addButton)
        countRow.widthAnchor.constraint(equalToConstant: 212).isActive = true
        sidebar.addArrangedSubview(countRow)
        taskList = TaskListStack()
        taskList.orientation = .vertical
        taskList.alignment = .leading
        taskList.spacing = 12
        let taskScroll = NSScrollView()
        taskScrollView = taskScroll
        taskScroll.drawsBackground = false
        taskScroll.hasVerticalScroller = true
        taskScroll.autohidesScrollers = true
        taskScroll.borderType = .noBorder
        taskScroll.documentView = taskList
        taskScroll.widthAnchor.constraint(equalToConstant: 214).isActive = true
        taskScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 80).isActive = true
        taskScroll.setContentHuggingPriority(.init(1), for: .vertical)
        taskList.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            taskList.leadingAnchor.constraint(equalTo: taskScroll.contentView.leadingAnchor),
            taskList.topAnchor.constraint(equalTo: taskScroll.contentView.topAnchor),
            taskList.widthAnchor.constraint(equalTo: taskScroll.contentView.widthAnchor)
        ])
        sidebar.addArrangedSubview(taskScroll)
        let actions = NSStackView()
        actions.orientation = .vertical
        actions.alignment = .leading
        actions.spacing = 5
        actions.addArrangedSubview(label("手动动作", size: 11, weight: .semibold))
        let choices: [(EmployeeAction, String)] = [(.coffee, "cup.and.saucer.fill"), (.stretch, "figure.flexibility"),
                                                  (.wave, "hand.wave.fill"), (.playWithCat, "cat.fill")]
        for first in stride(from: 0, to: choices.count, by: 2) {
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 6
            for (kind, symbol) in choices[first..<(first + 2)] {
                let button = ActionButton(kind.title, symbol: symbol) { [weak self] in self?.playAction(kind) }
                button.controlSize = .small
                button.font = .systemFont(ofSize: 11)
                button.widthAnchor.constraint(equalToConstant: 103).isActive = true
                button.heightAnchor.constraint(equalToConstant: 24).isActive = true
                button.setAccessibilityLabel(kind.title)
                button.toolTip = "播放\(kind.title)动作，结束后恢复原状态"
                actionButtons[kind] = button
                row.addArrangedSubview(button)
            }
            actions.addArrangedSubview(row)
        }
        let actionStatus = NSStackView()
        actionStatus.orientation = .horizontal
        actionStatus.alignment = .centerY
        actionStatus.spacing = 6
        actionStatus.widthAnchor.constraint(equalToConstant: 212).isActive = true
        actionStatus.heightAnchor.constraint(equalToConstant: 18).isActive = true
        actionStatusLabel = label("自动模式下偶尔起身溜达", size: 10, color: AppPalette.secondary)
        actionStatusLabel.lineBreakMode = .byTruncatingTail
        actionStatusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        actionStatus.addArrangedSubview(actionStatusLabel)
        actionStatus.addArrangedSubview(spacer())
        stopActionButton = ActionButton("结束") { [weak self] in self?.finishAction() }
        stopActionButton.bezelStyle = .inline
        stopActionButton.isBordered = false
        stopActionButton.controlSize = .small
        stopActionButton.font = .systemFont(ofSize: 10)
        stopActionButton.setAccessibilityLabel("结束动作")
        stopActionButton.widthAnchor.constraint(equalToConstant: 34).isActive = true
        actionStatus.addArrangedSubview(stopActionButton)
        actions.addArrangedSubview(actionStatus)
        sidebar.addArrangedSubview(actions)
        activityLabel = label("准备开工", size: 12, weight: .medium, color: AppPalette.green)
        sidebar.addArrangedSubview(activityLabel)
        sourceFootnote = label("本机与开发机 · 只读同步\n关闭窗口后，菜单栏继续运行", size: 10, color: AppPalette.secondary)
        sourceFootnote.maximumNumberOfLines = 2
        sidebar.addArrangedSubview(sourceFootnote)

        let content = NSStackView(views: [sceneWrap, sidebar])
        content.orientation = .horizontal
        content.alignment = .height
        content.spacing = 14

        let footer = NSStackView()
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 14
        modePicker = NSSegmentedControl(labels: ["自动", "坐着打工", "摸鱼", "站着打工"], trackingMode: .selectOne, target: self, action: #selector(modeChanged))
        modePicker.segmentStyle = .rounded
        modePicker.controlSize = .large
        modePicker.font = .systemFont(ofSize: 12, weight: .medium)
        for index in 0..<4 { modePicker.setWidth(index == 0 ? 58 : 90, forSegment: index) }
        footer.addArrangedSubview(modePicker)
        footer.addArrangedSubview(spacer())
        demoProgress = NSProgressIndicator()
        demoProgress.style = .bar
        demoProgress.isIndeterminate = false
        demoProgress.minValue = 0
        demoProgress.maxValue = 1
        demoProgress.widthAnchor.constraint(equalToConstant: 90).isActive = true
        demoProgress.isHidden = true
        footer.addArrangedSubview(demoProgress)
        demoButton = ActionButton("播放一分钟演示", symbol: "play.fill") { [weak self] in
            self?.toggleDemo()
        }
        footer.addArrangedSubview(demoButton)

        for view in [header, content, footer] { view.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(view) }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 42),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 26),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            header.heightAnchor.constraint(equalToConstant: 56),
            content.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 18),
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            content.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -16),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 26),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
            footer.heightAnchor.constraint(equalToConstant: 42)
        ])
    }

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "desktopcomputer", accessibilityDescription: "虚拟工位")
        let menu = NSMenu()
        sourceMenuTitle = menu.addItem(withTitle: "虚拟工位 · Codex 实时", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        let open = menu.addItem(withTitle: "打开工位", action: #selector(openWindow), keyEquivalent: "")
        open.target = self
        let inboxItem = menu.addItem(withTitle: "门外待办", action: #selector(openPendingNotes), keyEquivalent: "")
        inboxItem.keyEquivalent = "n"
        inboxItem.keyEquivalentModifierMask = [.control, .option, .command]
        inboxItem.target = self
        notesMenuItems.append(inboxItem)
        let demo = menu.addItem(withTitle: "播放 / 停止演示", action: #selector(toggleDemo), keyEquivalent: "")
        demo.target = self
        menu.addItem(withTitle: "使用 Codex 实时任务", action: #selector(useLiveTasks), keyEquivalent: "").target = self
        menu.addItem(withTitle: "使用 Claude 实时任务", action: #selector(useClaudeTasks), keyEquivalent: "").target = self
        menu.addItem(withTitle: "屏幕场景与环境…", action: #selector(openSceneSettings), keyEquivalent: "").target = self
        let settings = menu.addItem(withTitle: "壁纸与屏保设置", action: #selector(openScreenSaverSettings), keyEquivalent: "")
        settings.target = self
        let immersive = menu.addItem(withTitle: "进入沉浸全屏", action: #selector(toggleFullScreen), keyEquivalent: "")
        immersive.target = self
        let wallpaper = menu.addItem(withTitle: "设为桌面背景", action: #selector(toggleWallpaper), keyEquivalent: "")
        wallpaper.target = self
        wallpaperMenuItems.append(wallpaper)
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出虚拟工位", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q").target = NSApp
        statusItem.menu = menu
    }

    private var currentSnapshot: SceneSnapshot {
        var snapshot = usesLiveSource ? (liveSource?.snapshot ?? .empty()) : simulator.snapshot
        snapshot.action = currentAction.flatMap { $0.isActive(at: Date()) ? $0 : nil }
        snapshot.world = world
        snapshot.pendingNotes = notesInbox?.notes ?? []
        return snapshot
    }

    @objc private func openPendingNotes() {
        notesPanel.show(snapshot: currentSnapshot)
        notesPanel.update(snapshot: currentSnapshot, error: notesError, canUndo: notesInbox?.canUndo ?? false)
    }

    private func addPendingNote(_ text: String) {
        guard let notesInbox else { return }
        do {
            try notesInbox.add(text)
            notesError = nil
            notesPanel.didAddNote()
        } catch { notesError = error.localizedDescription }
        update()
    }

    private func removePendingNote(_ id: String) {
        guard let notesInbox else { return }
        do { try notesInbox.remove(id: id); notesError = nil }
        catch { notesError = error.localizedDescription }
        update()
    }

    private func undoPendingNoteRemoval() {
        guard let notesInbox else { return }
        do { try notesInbox.undoRemoval(); notesError = nil }
        catch { notesError = error.localizedDescription }
        update()
    }

    /// Save defaults once for each physical display. Focus, unplugging and later
    /// changes to the menu-bar screen must not silently replace a user's choices.
    private func establishDisplayDefaults() {
        world = worldWithDisplayDefaults(world)
        do { try worldStore.write(world); worldSettingsError = nil; sceneSettings.clearSaveError() }
        catch {
            worldSettingsError = error.localizedDescription
            sceneSettings.showSaveError(error.localizedDescription)
        }
    }

    private func worldWithDisplayDefaults(_ value: SceneWorld) -> SceneWorld {
        let displays = DisplaySceneRouting.descriptors()
        let connected = Set(displays.map(\.id))
        var next = value
        for context in SceneDisplayContext.allCases {
            var choices = next.displayScenes(for: context)
            for display in displays where choices[display.id] == nil {
                if choices.count >= 32,
                   let unused = choices.keys.sorted().first(where: { !connected.contains($0) }) {
                    choices.removeValue(forKey: unused)
                }
                guard choices.count < 32 else { continue }
                choices[display.id] = DisplaySceneRouting.background(for: display, among: displays,
                                                                    world: value, context: context)
            }
            next.setDisplayScenes(choices, for: context)
        }
        return next
    }

    private func saveWorld(_ value: SceneWorld) {
        let next = worldWithDisplayDefaults(value)
        do {
            try worldStore.write(next)
            world = next
            worldSettingsError = nil
            sceneSettings.clearSaveError()
            sceneSettings.update(snapshot: currentSnapshot)
            update()
        } catch {
            worldSettingsError = error.localizedDescription
            sceneSettings.update(snapshot: currentSnapshot)
            sceneSettings.showSaveError(error.localizedDescription)
        }
    }

    @objc private func openSceneSettings() {
        sceneSettings.show(snapshot: currentSnapshot)
        if let worldSettingsError { sceneSettings.showSaveError(worldSettingsError) }
    }

    private func update(persist: Bool = true) {
        if let action = currentAction, !action.isActive(at: Date()) { currentAction = nil }
        if ambientActionsEnabled, persist {
            let now = Date()
            if let action = ambientMotion.poll(snapshot: currentSnapshot, currentAction: currentAction,
                                               reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                                               at: now) { currentAction = action }
        }
        let snapshot = currentSnapshot
        scene.snapshot = snapshot
        presentation.update(snapshot)
        sceneSettings.update(snapshot: snapshot)
        let pendingCount = snapshot.pendingNotes?.count ?? 0
        let theme = world.theme
        let underwater = theme == .underwater
        let notesTitle = theme.notesTitle
        notesButton?.title = "\(notesTitle) \(pendingCount)" + (notesError == nil ? "" : " !")
        notesButton?.toolTip = notesError ?? (quickNoteHotKey.isRegistered
            ? "\(QuickNoteHotKey.displayShortcut) 快速记录 · ⌘↩ 添加访客"
            : "全局快捷键被占用或无法注册；请用 ⌘2 打开待办，⌘↩ 添加")
        for item in notesMenuItems { item.title = "\(notesTitle)（\(pendingCount)）" }
        notesPanel.update(snapshot: snapshot, error: notesError, canUndo: notesInbox?.canUndo ?? false)
        let modes = modeChoices
        if modePicker.segmentCount != modes.count { modePicker.segmentCount = modes.count }
        for (index, mode) in modes.enumerated() where modePicker.label(forSegment: index) != mode.1 {
            modePicker.setLabel(mode.1, forSegment: index)
            modePicker.setWidth(!underwater && index == 0 ? 58 : 90, forSegment: index)
        }
        modePicker.selectedSegment = modes.firstIndex { $0.0 == snapshot.mode } ?? 0
        for (action, button) in actionButtons {
            let title = theme.title(for: action)
            guard button.title != title else { continue }
            button.title = title
            button.setAccessibilityLabel(title)
            button.toolTip = "播放\(title)动作，结束后恢复原状态"
            if action == .coffee || action == .playWithCat {
                let symbol = underwater ? (action == .coffee ? "bubbles.and.sparkles.fill" : "heart.fill")
                    : (action == .coffee ? "cup.and.saucer.fill" : "cat.fill")
                button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            }
        }
        walkMenuItem?.title = theme.title(for: EmployeeAction.walk)
        sourcePicker.selectedSegment = usesLiveSource ? (liveOrigin == .claude ? 1 : 0) : 2
        let demoHint = underwater ? "任务会显示在水中的潜水艇上。\n模拟任务仅用于查看效果。"
            : "基础三屏，随任务扩展。\n模拟任务仅用于查看效果。"
        sourceHint.stringValue = usesLiveSource ? (liveSource?.connectionMessage ?? "正在连接 \(liveAgent)…") : demoHint
        sourceHint.toolTip = sourceHint.stringValue
        sourceFootnote.stringValue = usesLiveSource ? "\(liveOrigin == .claude ? "本机 Claude Code" : "本机与开发机") · 只读同步\n关闭窗口后，菜单栏继续运行" : "模拟任务 · 无需联网\n关闭窗口后，菜单栏继续运行"
        sourceMenuTitle?.title = usesLiveSource ? "虚拟工位 · \(liveAgent) 实时" : "虚拟工位 · 模拟任务"
        if usesLiveSource {
            let total = liveSource?.totalSessionCount ?? snapshot.tasks.count
            taskCount.stringValue = total > snapshot.tasks.count ? "会话  \(snapshot.tasks.count) / \(total) · 显示前六" : "\(liveAgent)  \(total) 个会话"
            taskCount.toolTip = underwater ? "按真实会话同步，最多同时显示六艘任务潜水艇。"
                : "按真实会话同步；最多同时显示六块任务屏。"
        } else {
            taskCount.stringValue = "会话  \(snapshot.tasks.count) / 6"
            taskCount.toolTip = nil
        }
        addButton.isHidden = usesLiveSource
        addButton.isEnabled = !usesLiveSource && snapshot.tasks.count < 6
        demoButton.title = usesLiveSource ? "查看模拟演示" : snapshot.demoRunning ? "停止演示" : "播放一分钟演示"
        demoButton.image = NSImage(systemSymbolName: snapshot.demoRunning ? "stop.fill" : "play.fill", accessibilityDescription: demoButton.title)
        demoProgress.isHidden = usesLiveSource || !snapshot.demoRunning
        demoProgress.doubleValue = usesLiveSource ? 0 : simulator.demoProgress
        actionStatusLabel.stringValue = snapshot.action.map { "正在\(theme.title(for: $0.kind))" }
            ?? (underwater ? "当前状态 · \(modes[modePicker.selectedSegment].1)" : "自动模式下偶尔起身溜达")
        actionStatusLabel.textColor = snapshot.action == nil ? AppPalette.secondary : AppPalette.green
        stopActionButton.isHidden = snapshot.action == nil
        switch snapshot.resolvedActivity() {
        case .working: activityLabel.stringValue = "● 分身正在替你打工"; activityLabel.textColor = AppPalette.green
        case .waiting: activityLabel.stringValue = "◷ 等你回来处理一下"; activityLabel.textColor = AppPalette.waiting
        case .resting: activityLabel.stringValue = underwater ? "◌ 正在浅海潜水" : "☕ 现在是摸鱼时间"; activityLabel.textColor = AppPalette.secondary
        case .offline: activityLabel.stringValue = underwater ? "○ 任务同步已暂停" : "○ 工位暂时离线"; activityLabel.textColor = AppPalette.secondary
        }
        // Progress changes every second; rebuilding controls would dismiss a
        // status menu while the user is choosing an item.
        let connected = usesLiveSource ? liveSource?.isConnected : nil
        let taskControlsChanged = connected != previousSourceConnected || snapshot.tasks.count != previousTasks.count || zip(snapshot.tasks, previousTasks).contains {
            $0.id != $1.id || $0.title != $1.title || $0.status != $1.status || $0.slot != $1.slot
                || $0.hostID != $1.hostID || $0.hostName != $1.hostName
                || $0.executionDetails?.phase != $1.executionDetails?.phase
                || $0.executionDetails?.toolName != $1.executionDetails?.toolName
                || $0.executionDetails?.latestUpdate != $1.executionDetails?.latestUpdate
                || $0.startedAt != $1.startedAt
        }
        if !hasBuiltTasks || taskControlsChanged {
            rebuildTasks(snapshot.tasks)
            previousTasks = snapshot.tasks
            previousSourceConnected = connected
            hasBuiltTasks = true
        }
        syncLabel.stringValue = usesLiveSource ? ((liveSource?.isConnected ?? false) ? "● \(liveAgent) 实时" : "○ \(liveAgent) 未连接") : "● 模拟任务"
        syncLabel.textColor = usesLiveSource && !(liveSource?.isConnected ?? false) ? AppPalette.secondary : AppPalette.green
        syncLabel.toolTip = (usesLiveSource ? "\(liveSource?.connectionMessage ?? "正在连接")\n" : "") + "状态文件：\(stateURL.path)"
        guard persist else { return }
        do {
            try store.write(snapshot)
            lastWriteError = nil
        } catch {
            lastWriteError = error.localizedDescription
            syncLabel.stringValue = "⚠ 同步失败"
            syncLabel.textColor = .systemOrange
            syncLabel.toolTip = error.localizedDescription
        }
    }

    /// Exercises the production view hierarchy without ordering a window on screen,
    /// starting the simulator timer, touching the state file, or creating a status item.
    func renderInterface(output: URL?, size: NSSize, taskCount: Int, mode: EmployeeMode,
                         action: EmployeeAction? = nil, actionTime: TimeInterval = 0,
                         theme: WorkplaceTheme = .cabin) throws -> String {
        world.theme = theme
        usesLiveSource = false
        simulator = TaskSimulator()
        for _ in 0..<min(6, max(0, taskCount)) { simulator.addTask() }
        simulator.setMode(mode)
        if let action {
            currentAction = SceneAction(kind: action, startedAt: Date().addingTimeInterval(-max(0, actionTime)))
        }
        buildWindow()
        window.setContentSize(size)
        update(persist: false)
        guard let root = window.contentView else { throw layoutError("Missing content view") }
        root.layoutSubtreeIfNeeded()
        taskList.layoutSubtreeIfNeeded()
        root.layoutSubtreeIfNeeded()
        let sceneFrame = sceneContainer.convert(sceneContainer.bounds, to: root)
        let sidebarFrame = sidebarContainer.convert(sidebarContainer.bounds, to: root)
        guard sceneFrame.width > 300, sceneFrame.height > 200,
              sidebarFrame.width > 200, sidebarFrame.height > 200 else {
            throw layoutError("Non-positive or collapsed scene/sidebar: \(sceneFrame), \(sidebarFrame)")
        }
        guard !sceneFrame.intersects(sidebarFrame) else { throw layoutError("Scene overlaps sidebar") }
        guard taskScrollView.bounds.height >= 79, taskScrollView.hasVerticalScroller,
              taskList.arrangedSubviews.count == taskCount || taskCount == 0 else {
            throw layoutError("Task list is not scrollable or lost rows")
        }
        if taskList.frame.height > taskScrollView.contentView.bounds.height,
           let last = taskList.arrangedSubviews.last {
            let bottom = taskList.frame.height - taskScrollView.contentView.bounds.height
            taskScrollView.contentView.scroll(to: NSPoint(x: 0, y: bottom))
            let lastFrame = last.convert(last.bounds, to: taskScrollView.contentView)
            guard taskScrollView.contentView.bounds.intersects(lastFrame) else {
                throw layoutError("The final task cannot be reached by scrolling")
            }
            taskScrollView.contentView.scroll(to: .zero)
        }
        for view in [sceneContainer!, sidebarContainer!, modePicker!, demoButton!, notesButton!] {
            let frame = view.convert(view.bounds, to: root)
            guard root.bounds.insetBy(dx: -1, dy: -1).contains(frame) else {
                throw layoutError("A control extends outside content: \(frame), root: \(root.bounds)")
            }
        }
        if let output = output {
            guard let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) else {
                throw layoutError("Cannot allocate interface image")
            }
            root.cacheDisplay(in: root.bounds, to: bitmap)
            guard let data = bitmap.representation(using: .png, properties: [:]) else {
                throw layoutError("Cannot encode interface image")
            }
            try data.write(to: output, options: .atomic)
        }
        let report = "PASS \(Int(size.width))×\(Int(size.height)): scene \(Int(sceneFrame.width))×\(Int(sceneFrame.height)), sidebar \(Int(sidebarFrame.width))×\(Int(sidebarFrame.height)), task viewport \(Int(taskScrollView.bounds.height)), document \(Int(taskList.frame.height)), \(taskCount) tasks"
        window.delegate = nil
        window.close()
        return report
    }

    private func layoutError(_ message: String) -> NSError {
        NSError(domain: "VirtualWorkplace.Layout", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func rebuildTasks(_ tasks: [WorkplaceTask]) {
        let scrollOrigin = taskScrollView.contentView.bounds.origin
        defer {
            taskList.layoutSubtreeIfNeeded()
            taskScrollView.layoutSubtreeIfNeeded()
            let clip = taskScrollView.contentView
            let maxY = max(0, taskList.frame.height - clip.bounds.height)
            clip.scroll(to: NSPoint(x: scrollOrigin.x, y: min(maxY, max(0, scrollOrigin.y))))
            taskScrollView.reflectScrolledClipView(clip)
        }
        for child in taskList.arrangedSubviews { taskList.removeArrangedSubview(child); child.removeFromSuperview() }
        if tasks.isEmpty {
            let emptyText = usesLiveSource ? ((liveSource?.isConnected ?? false) ? "当前没有运行中的会话。\n\(liveAgent) 开始工作后会自动出现。" : "正在等候 \(liveAgent) 状态。\n连接后会自动显示真实任务。") : "工位很安静。\n添加任务，在屏幕上查看进展。"
            let empty = label(emptyText, size: 11, color: AppPalette.secondary)
            empty.maximumNumberOfLines = 3
            empty.widthAnchor.constraint(equalToConstant: 210).isActive = true
            taskList.addArrangedSubview(empty)
            return
        }
        let statuses: [TaskStatus] = [.running, .waiting, .completed, .failed]
        for task in tasks.sorted(by: { $0.slot < $1.slot }) {
            let block = NSStackView()
            block.orientation = .vertical
            block.alignment = .leading
            block.spacing = 4
            let header = NSStackView()
            header.orientation = .horizontal
            header.spacing = 4
            header.widthAnchor.constraint(equalToConstant: 212).isActive = true
            let title = label(String(format: "%02d", task.slot + 1) + "  " + task.title, size: 11, weight: .medium)
            title.lineBreakMode = .byTruncatingTail
            title.toolTip = usesLiveSource ? "\(task.title)\n来源：\(task.sourceLabel)" : task.title
            header.addArrangedSubview(title)
            header.addArrangedSubview(spacer())
            if !usesLiveSource {
                let close = ActionButton("", symbol: "xmark") { [weak self] in self?.mutate { $0.removeTask(id: task.id) } }
                close.bezelStyle = .inline
                close.isBordered = false
                close.toolTip = "关闭会话；基础屏恢复概览，扩展屏收起"
                close.setAccessibilityLabel("关闭会话：\(task.title)")
                close.widthAnchor.constraint(equalToConstant: 20).isActive = true
                header.addArrangedSubview(close)
            }
            block.addArrangedSubview(header)
            if usesLiveSource {
                let prefixes: [TaskStatus: String] = [.running: "● ", .waiting: "◷ ", .completed: "✓ ", .failed: "! "]
                let connected = liveSource?.isConnected ?? false
                let text = connected ? (prefixes[task.status] ?? "") + task.activityTitle + " · " + task.sourceLabel : "○ 状态未知 · 已断开"
                let color = !connected || task.status == .idle ? AppPalette.secondary : task.status == .waiting ? AppPalette.waiting : task.status == .failed ? NSColor.systemOrange : AppPalette.green
                let status = label(text, size: 11, color: color)
                status.lineBreakMode = .byTruncatingTail
                status.widthAnchor.constraint(equalToConstant: 212).isActive = true
                status.toolTip = "来源：\(task.sourceLabel)\n真实状态由 \(liveAgent) 同步，在 \(liveAgent) 会话中处理。"
                block.addArrangedSubview(status)
                if connected, let details = task.executionDetails {
                    if task.status == .running, details.phase == .tool, let tool = details.toolName {
                        let toolLabel = label("工具 · \(tool)", size: 10, color: AppPalette.green)
                        toolLabel.lineBreakMode = .byTruncatingTail
                        toolLabel.widthAnchor.constraint(equalToConstant: 212).isActive = true
                        toolLabel.toolTip = tool
                        block.addArrangedSubview(toolLabel)
                    }
                    if let latest = details.latestUpdate, !latest.isEmpty {
                        let recent = NSTextField(wrappingLabelWithString: "最近更新：\(latest)")
                        recent.font = .systemFont(ofSize: 10)
                        recent.textColor = AppPalette.secondary
                        recent.maximumNumberOfLines = 2
                        recent.lineBreakMode = .byWordWrapping
                        recent.widthAnchor.constraint(equalToConstant: 212).isActive = true
                        recent.toolTip = latest
                        block.addArrangedSubview(recent)
                    }
                }
                taskList.addArrangedSubview(block)
                continue
            }
            let popup = TaskStatusPopup(frame: .zero, pullsDown: false)
            popup.addItems(withTitles: ["● 工作中", "◷ 等待确认", "✓ 已完成", "! 出错"])
            popup.selectItem(at: statuses.firstIndex(of: task.status) ?? 0)
            popup.widthAnchor.constraint(equalToConstant: 212).isActive = true
            popup.actionHandler = { [weak self] index in
                guard statuses.indices.contains(index) else { return }
                self?.mutate { $0.setTaskStatus(id: task.id, status: statuses[index]) }
            }
            block.addArrangedSubview(popup)
            taskList.addArrangedSubview(block)
        }
    }

    private func mutate(_ action: (TaskSimulator) -> Void) {
        guard !usesLiveSource else { return }
        if simulator.snapshot.demoRunning { simulator.setDemoRunning(false) }
        action(simulator)
        update()
    }

    private func playAction(_ kind: EmployeeAction) {
        ambientMotion.postpone(at: Date())
        currentAction = SceneAction(kind: kind, startedAt: Date())
        update()
    }

    @objc private func takeWalk() { playAction(.walk) }

    private func finishAction() {
        ambientMotion.postpone(at: Date())
        currentAction = nil
        update()
    }

    private var modeChoices: [(EmployeeMode, String)] {
        if world.theme == .underwater { return [(.sitting, "漂浮"), (.standing, "巡游"), (.slacking, "划水")] }
        return [(.automatic, "自动"), (.sitting, "坐着打工"), (.slacking, "摸鱼"), (.standing, "站着打工")]
    }

    @objc private func modeChanged() {
        let modes = modeChoices
        guard modes.indices.contains(modePicker.selectedSegment) else { return }
        currentAction = nil
        ambientMotion.reset()
        let mode = modes[modePicker.selectedSegment].0
        if usesLiveSource { liveSource?.setMode(mode, at: Date()); update() }
        else { mutate { $0.setMode(mode) } }
    }

    @objc private func sourceChanged() {
        let segment = sourcePicker.selectedSegment
        if segment == 2 { selectSource(live: false) }
        else { selectSource(live: true, origin: segment == 1 ? .claude : .codex) }
    }
    @objc private func useLiveTasks() { selectSource(live: true, origin: .codex) }
    @objc private func useClaudeTasks() { selectSource(live: true, origin: .claude) }

    private func selectSource(live: Bool, origin: WorkplaceTaskOrigin? = nil) {
        let target = origin ?? liveOrigin
        guard live != usesLiveSource || (live && target != liveOrigin) else { return }
        let preferences = currentSnapshot
        simulator.setDemoRunning(false)
        // Only one live observer runs at a time.
        if usesLiveSource { liveSource?.stop() }
        usesLiveSource = live
        liveOrigin = target
        hasBuiltTasks = false
        if live {
            if preferences.mode == .automatic {
                liveSource?.setMode(preferences.preferredPosture == .standing ? .standing : .sitting, at: Date())
            }
            liveSource?.setMode(preferences.mode, at: Date())
            liveSource?.start()
        } else {
            if preferences.mode == .automatic {
                simulator.setMode(preferences.preferredPosture == .standing ? .standing : .sitting)
            }
            simulator.setMode(preferences.mode)
            simulator.tick()
        }
        update()
    }

    @objc private func toggleDemo() {
        if usesLiveSource { selectSource(live: false) }
        simulator.setDemoRunning(!simulator.snapshot.demoRunning)
        update()
    }
    @objc private func toggleFullScreen() {
        if presentation.immersiveEnabled { presentation.hideImmersive(returnToControls: true) }
        else {
            presentation.showImmersive(on: window.screen)
            window.orderOut(nil)
            scene.stopAnimating()
        }
    }
    @objc private func toggleWallpaper() { presentation.setWallpaperEnabled(!presentation.wallpaperEnabled) }
    private func refreshWallpaperControls(enabled: Bool) {
        wallpaperButton?.title = enabled ? "关闭背景" : "桌面背景"
        for item in wallpaperMenuItems {
            item.title = enabled ? "关闭桌面背景" : "设为桌面背景"
            item.state = enabled ? .on : .off
        }
    }
    @objc private func openWindow() {
        presentation.hideImmersive(returnToControls: false)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        scene.startAnimating()
    }
    @objc private func willSleep() { ambientMotion.reset(); scene.stopAnimating(); presentation.stopAnimations() }
    @objc private func didWake() {
        if window.isVisible && !window.isMiniaturized { scene.startAnimating() }
        presentation.resumeAnimations()
        if usesLiveSource { liveSource?.tick(at: Date()) } else { simulator.tick() }
        update()
    }
    func windowWillClose(_ notification: Notification) { scene.stopAnimating() }
    func windowDidMiniaturize(_ notification: Notification) { scene.stopAnimating() }
    func windowDidDeminiaturize(_ notification: Notification) { scene.startAnimating() }
    func windowDidChangeOcclusionState(_ notification: Notification) {
        if window.occlusionState.contains(.visible) { scene.startAnimating() } else { scene.stopAnimating() }
    }

    @objc private func installScreenSaver() {
        guard !isInstallingScreenSaver else { return }
        isInstallingScreenSaver = true
        screenSaverInstallButton?.isEnabled = false
        screenSaverInstallButton?.title = "正在安装…"
        // Bundle validation and signature checking run outside the UI thread.
        let installer = ScreenSaverInstaller()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Swift.Result { try installer.install() }
            DispatchQueue.main.async {
                guard let self else { return }
                self.isInstallingScreenSaver = false
                self.screenSaverInstallButton?.isEnabled = true
                self.screenSaverInstallButton?.title = "安装屏保"
                let alert = NSAlert()
                switch result {
                case .success(let installed):
                    alert.messageText = installed.replacedExisting ? "屏保已更新" : "屏保已安装"
                    alert.informativeText = "接下来在系统设置的「墙纸」中点击「屏幕保护程序」，在「其他」分类选择 VirtualWorkplace（可能需要点「显示全部」）。\n\n主应用保持运行时，屏保会同步工位和任务。系统可能暂存旧版屏保。若仍显示旧画面，先退出并重开系统设置；仍未更新时，请在方便时重新登录或重启 Mac。"
                    alert.addButton(withTitle: "打开屏保设置")
                    alert.addButton(withTitle: "在 Finder 中显示")
                    alert.addButton(withTitle: "完成")
                    alert.beginSheetModal(for: self.window) { response in
                        if response == .alertFirstButtonReturn { self.openScreenSaverSettings() }
                        else if response == .alertSecondButtonReturn {
                            NSWorkspace.shared.activateFileViewerSelecting([installed.destination])
                        }
                    }
                case .failure(let error):
                    alert.alertStyle = .warning
                    alert.messageText = "屏保安装未完成"
                    alert.informativeText = error.localizedDescription
                    alert.addButton(withTitle: "好")
                    alert.beginSheetModal(for: self.window)
                }
            }
        }
    }

    @objc private func openScreenSaverSettings() {
        // Tahoe removed the standalone ScreenSaver settings extension. Opening
        // its old URL succeeds but lands on General, so use Wallpaper directly.
        for address in ["x-apple.systempreferences:com.apple.Wallpaper-Settings.extension"] {
            if let url = URL(string: address), NSWorkspace.shared.open(url) { return }
        }
        let alert = NSAlert()
        alert.messageText = "请手动打开屏保设置"
        alert.informativeText = "打开「系统设置」→「墙纸」→「屏幕保护程序」，在「其他」分类中选择 VirtualWorkplace。"
        alert.addButton(withTitle: "好")
        alert.beginSheetModal(for: window)
    }

    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "虚拟工位 0.9.4"
        alert.informativeText = "把任务交给工位里的自己。\n\nCodex、Claude Code 实时任务与模拟演示可切换。\n实时模式只读同步本机与已连接开发机的会话，未知进度不显示百分比。\n支持独立窗口、桌面背景和 macOS 系统屏保。"
        alert.addButton(withTitle: "继续上班")
        alert.runModal()
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = AppPalette.ink) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.isSelectable = false
        return field
    }

    private func spacer(vertical: Bool = false) -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.init(1), for: vertical ? .vertical : .horizontal)
        view.setContentCompressionResistancePriority(.init(1), for: vertical ? .vertical : .horizontal)
        return view
    }
}
