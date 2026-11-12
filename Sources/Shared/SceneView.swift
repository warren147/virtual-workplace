import AppKit

final class WorkplaceSceneView: NSView {
    var snapshot: SceneSnapshot = .empty() {
        didSet {
            updateSceneAccessibility()
            refreshStaticFrame()
        }
    }
    var background: WorkplaceBackground = .room {
        didSet {
            guard oldValue != background else { return }
            animation.reset()
            updateSceneAccessibility()
            refreshStaticFrame()
        }
    }
    var viewport: WorldViewport? {
        didSet {
            guard oldValue != viewport else { return }
            refreshStaticFrame()
        }
    }
    var isScreenSaver = false
    var maximumFramesPerSecond: Int = 30 {
        didSet { if timer != nil { stopAnimating(); startAnimating() } }
    }
    private var timer: Timer?
    var isAnimating: Bool { timer != nil }
    private let animation = SceneAnimation()
    private var suspended = false
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    override init(frame: NSRect) { super.init(frame: frame); configure() }
    required init?(coder: NSCoder) { super.init(coder: coder); configure() }
    deinit { stopAnimating(); observers.forEach { $0.0.removeObserver($0.1) } }

    private func configure() {
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("虚拟工位场景")
        updateSceneAccessibility()
        layer?.backgroundColor = NSColor(calibratedRed:0.957,green:0.941,blue:0.906,alpha:1).cgColor
        let center = NSWorkspace.shared.notificationCenter
        observers.append((center, center.addObserver(forName:NSWorkspace.screensDidSleepNotification,object:nil,queue:.main) { [weak self] _ in
            self?.suspended = true; self?.stopAnimating()
        }))
        observers.append((center, center.addObserver(forName:NSWorkspace.screensDidWakeNotification,object:nil,queue:.main) { [weak self] _ in
            self?.suspended = false; self?.refreshStaticFrame(); self?.startAnimating()
        }))
        observers.append((NotificationCenter.default, NotificationCenter.default.addObserver(forName:NSWindow.didChangeOcclusionStateNotification,object:nil,queue:.main) { [weak self] note in
            guard let self, let changed=note.object as? NSWindow, changed === self.window else { return }
            if changed.occlusionState.contains(.visible) { self.startAnimating() } else { self.stopAnimating() }
        }))
        observers.append((center, center.addObserver(forName:NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,object:nil,queue:.main) { [weak self] _ in
            self?.stopAnimating(); self?.startAnimating()
        }))
    }
    private func updateSceneAccessibility() {
        let world = snapshot.effectiveWorld(at: Date())
        let theme = world.theme
        if theme == .underwater {
            let title = theme.title(for: background)
            let condition = theme.title(for: world.weather)
            if background == .outdoors {
                let count = snapshot.pendingNotes?.count ?? 0
                setAccessibilityValue("\(title)，\(condition)，\(count) 位访客等待交办")
            } else {
                let action = snapshot.action.flatMap { $0.isActive() ? "，正在\(theme.title(for: $0.kind))" : nil } ?? ""
                setAccessibilityValue("\(title)潜游，\(condition)，\(snapshot.tasks.count) 艘任务潜水艇\(action)")
            }
        } else if background == .outdoors {
            let notes = snapshot.pendingNotes ?? []
            let waiting = notes.isEmpty ? "门外暂无待办" : "\(notes.count) 位访客等待交办"
            setAccessibilityValue("窗外风景，\(world.weather.title)，\(world.environment(at: Date()).title)，\(waiting)")
        } else {
            let pose = snapshot.resolvedPose()
            let title = pose == .standing ? "站着打工" : pose == .sitting ? "坐着打工" : "摸鱼"
            let origin = snapshot.taskOrigin.flatMap { $0.isLive ? $0.agentName : nil } ?? "模拟"
            let action = snapshot.action.flatMap { $0.isActive() ? "，正在\($0.kind.title)" : nil } ?? ""
            setAccessibilityValue("\(title)，\(snapshot.tasks.count) 个\(origin)会话\(action)，\(world.weather.title)")
        }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { refreshStaticFrame(); startAnimating() } else { stopAnimating() }
    }
    override func viewDidHide() { super.viewDidHide(); stopAnimating() }
    override func viewDidUnhide() { super.viewDidUnhide(); refreshStaticFrame(); startAnimating() }
    private func refreshStaticFrame() {
        // Desktop/offscreen windows can retain a stale occlusion flag. Mark the
        // latest snapshot dirty even while their continuous timer is paused.
        // A single redraw must not leave newly added screens at opacity zero.
        if timer == nil { animation.reset() }
        if !suspended, !isHiddenOrHasHiddenAncestor, window != nil { needsDisplay = true }
    }
    func startAnimating() {
        guard timer == nil, !suspended, !isHiddenOrHasHiddenAncestor, let window, window.occlusionState.contains(.visible) else { return }
        animation.reset()
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let frames = min(60, max(1, maximumFramesPerSecond))
        let next=Timer(timeInterval:reduce ? 1:1.0/Double(frames),repeats:true) { [weak self] _ in self?.needsDisplay=true }
        next.tolerance=reduce ? 0.1:0.004
        timer=next;RunLoop.main.add(next,forMode:.common)
        needsDisplay=true
    }
    func stopAnimating() { timer?.invalidate();timer=nil;animation.reset() }
    override func draw(_ dirtyRect: NSRect) {
        guard let context=NSGraphicsContext.current?.cgContext else { return }
        if timer == nil { animation.reset() }
        SceneRenderer.draw(in:context,bounds:bounds,snapshot:snapshot,time:ProcessInfo.processInfo.systemUptime,
                           reduceMotion:NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,animation:animation,
                           background:background, viewport:resolvedViewport)
    }

    private var resolvedViewport: WorldViewport {
        if let viewport { return viewport }
        // The companion app always previews the room's main-screen camera,
        // even when its ordinary control window has been moved to the left.
        let screen = background == .room ? DisplaySceneRouting.mainScreen()
            : DisplaySceneRouting.screen(for: window)
        return DisplaySceneRouting.viewport(for: screen, world: snapshot.world ?? SceneWorld()) ?? .companion(for: background)
    }
}
