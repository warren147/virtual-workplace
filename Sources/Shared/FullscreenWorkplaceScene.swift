import AppKit
import CoreText

/// Original pixel cabin art + live native task data. Coordinates match the art
/// plate, 1672×941, so readable text never becomes baked into the background.
enum FullscreenWorkplaceScene {
    static let size = CGSize(width: 1672, height: 941)
    private static let ink = tint(0x34271E)
    private static let paper = tint(0xF5DBA6)
    private static let glow = tint(0xC4E4D2)
    private static let waitingGlow = tint(0x8FBFEA)
    /// The approved room has three permanent displays. Extra sessions add the
    /// upper row, while vacant desk displays keep useful overview information.
    static func displaySlots(for frame: SceneFrame) -> [Int] {
        Set([0, 1, 2]).union(frame.screens.filter { $0.1 > 0.005 }.map { $0.0.slot }).sorted(by: >)
    }

    static func draw(in c: CGContext, snapshot: SceneSnapshot, frame: SceneFrame, time: TimeInterval,
                     visibleRect: CGRect = CGRect(origin: .zero, size: size), actionProgress: CGFloat? = nil,
                     actionBlend: CGFloat = 0, reduceMotion: Bool = false, now: Date = Date(),
                     viewport: WorldViewport = .companion(for: .room), worldBounds: CGRect? = nil) {
        c.interpolationQuality = .none
        let world = snapshot.world ?? SceneWorld()
        if let bg = RoomAssets.background { c.draw(bg, in: CGRect(origin: .zero, size: size)) }
        else { fallbackRoom(c) }
        if let rug = RoomAssets.rugPatch {
            c.draw(rug, in: CGRect(x: 500, y: 55, width: 220, height: 135))
        }
        let nightBlend = world.environment(at: now).darkness
        if let night = RoomAssets.nightBackground, nightBlend > 0 {
            c.saveGState(); c.setAlpha(CGFloat(nightBlend))
            c.draw(night, in: CGRect(origin: .zero, size: size))
            c.restoreGState()
        }
        WorldAtmosphere.drawRoom(in: c, world: world, at: now, reduceMotion: reduceMotion,
                                 nightArtworkBlend: RoomAssets.nightBackground == nil ? 0 : nightBlend,
                                 visibleRect: worldBounds ?? visibleRect, viewport: viewport)
        c.saveGState()
        let seamClip = CGMutablePath()
        seamClip.addRect(worldBounds ?? visibleRect)
        seamClip.addRect(WindowGlassMask.bounds)
        c.addPath(seamClip); c.clip(using: .evenOdd)
        SceneSeamBlend.draw(in: c, bounds: worldBounds ?? visibleRect, world: world,
                            at: now, viewport: viewport)
        c.restoreGState()
        let rise = (frame.standing * 40).rounded()
        deskBase(c, rise: rise)
        // Tall mounts belong behind every panel so they cannot cross task text.
        for (task, opacity) in frame.screens where task.slot >= 3 && opacity > 0.005 {
            c.saveGState(); c.setAlpha(opacity)
            monitorMount(c, slot: task.slot, rise: rise)
            c.restoreGState()
        }
        for slot in displaySlots(for: frame) {
            if let task = snapshot.tasks.first(where: { $0.slot == slot }) {
                let opacity = frame.screens.first(where: { $0.0.id == task.id })?.1 ?? 1
                c.saveGState(); c.setAlpha(slot < 3 ? 1 : opacity)
                monitor(c, task: task, snapshot: snapshot, rise: rise, time: time)
                c.restoreGState()
            } else if slot < 3 {
                overviewMonitor(c, slot: slot, snapshot: snapshot, rise: rise)
            } else if let departing = frame.screens.first(where: { $0.0.slot == slot }) {
                c.saveGState(); c.setAlpha(departing.1)
                monitor(c, task: departing.0, snapshot: snapshot, rise: rise, time: time)
                c.restoreGState()
            }
        }
        desktop(c, rise: rise)
        let inputActivity: EmployeeActivity = actionProgress == nil ? snapshot.resolvedActivity(at: now) : .waiting
        inputDevices(c, rise: rise, motion: WorkInputMotion.sample(time: time, activity: inputActivity))
        // The tabletop asset includes foreground props. Desk stands must be
        // above the wood, while screen bodies remain behind those props.
        for slot in 0..<3 { monitorMount(c, slot: slot, rise: rise) }
        let resting = max(0, min(1, frame.slacking))
        let usesWalking = snapshot.action?.kind == .walk || snapshot.action?.kind == .playWithCat
        let gestureAvailable = EmployeeActionSprites.isAvailable && (!usesWalking || PixelWalkingSprites.isAvailable)
        let gestureBlend = gestureAvailable ? actionBlend : 0
        c.saveGState(); c.setAlpha((1 - resting) * (1 - gestureBlend))
        PixelEmployee.drawWorking(in: c, standing: frame.standing, time: time,
                                  activity: inputActivity, feet: CGPoint(x: 835, y: 270), pixelSize: 6)
        c.restoreGState()
        if PixelEmployee.hasSprites {
            c.saveGState(); c.setAlpha(resting + (1 - resting) * max(frame.standing, actionBlend))
            PixelEmployee.drawEmptyChair(in: c, standing: frame.standing, feet: CGPoint(x: 835, y: 270), pixelSize: 6)
            c.restoreGState()
        } else { chair(c, standing: frame.standing) }
        if let progress = actionProgress, let action = snapshot.action, gestureBlend > 0.005 {
            var feet = CGPoint(x: 835, y: 270)
            var walkSample: EmployeeWalkSample?
            if action.kind == .walk {
                let sample = AmbientEmployeeMotion.walkSample(progress: reduceMotion ? 0 : progress)
                feet = sample.feet; walkSample = sample
            }
            if action.kind == .playWithCat {
                let sample = AmbientEmployeeMotion.catVisitSample(progress: reduceMotion ? 0.5 : progress)
                feet = sample.feet
                if sample.isMoving || (!reduceMotion && (progress < 0.35 || progress > 0.65)) {
                    walkSample = sample
                }
            }
            c.saveGState(); c.setAlpha(gestureBlend)
            if let sample = walkSample {
                _ = PixelWalkingSprites.draw(in: c, direction: sample.direction, distance: sample.distance,
                                             isMoving: !reduceMotion && sample.isMoving, feet: feet, pixelSize: 6)
            } else {
                // The prop pose only appears after the employee reaches the
                // cat. Travel uses the same directional gait as a normal walk.
                let gestureProgress = action.kind == .playWithCat && !reduceMotion
                    ? max(0, min(1, (progress - 0.35) / 0.30)) : progress
                _ = EmployeeActionSprites.draw(in: c, kind: action.kind, progress: gestureProgress,
                                               time: reduceMotion ? 0 : time,
                                               feet: feet, pixelSize: 6)
            }
            c.restoreGState()
        }
        if resting > 0.005 {
            c.saveGState(); c.setAlpha(resting)
            PixelEmployee.drawSleeping(in: c, time: time, headCenter: CGPoint(x: min(1540, visibleRect.maxX - 53), y: 468), pixelSize: 5)
            PixelEmployee.drawSleepBubble(in: c, time: time, origin: CGPoint(x: min(1455, visibleRect.maxX - 162), y: 549), pixelSize: 4)
            c.restoreGState()
        }
        if RoomAssets.usesFlatForeground || RoomAssets.rugPatch != nil {
            PixelCat.draw(in: c, time: time,
                          interaction: snapshot.action?.kind == .playWithCat ? actionProgress : nil,
                          reduceMotion: reduceMotion)
        }
        wallBoard(c, snapshot: snapshot)
        clock(c, visibleRect: visibleRect, at: now)
        statusPlaque(c, snapshot: snapshot, actionTitle: actionProgress != nil ? snapshot.action?.kind.title : nil)
    }

    private static func tint(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
                blue: CGFloat(hex & 255) / 255, alpha: alpha)
    }
    private static func block(_ c: CGContext, _ rect: CGRect, _ color: NSColor) {
        c.setFillColor(color.cgColor); c.fill(rect.integral)
    }
    private static func panel(_ c: CGContext, _ r: CGRect, edge: NSColor, fill: NSColor, border: CGFloat = 4) {
        block(c, r, edge); block(c, r.insetBy(dx: border, dy: border), fill)
    }
    private static func label(_ text: String, at p: CGPoint, size: CGFloat, color: NSColor,
                              weight: NSFont.Weight = .regular, width: CGFloat = 500) {
        let style = NSMutableParagraphStyle(); style.lineBreakMode = .byTruncatingTail
        (text as NSString).draw(in: CGRect(x: p.x, y: p.y, width: width, height: size * 1.65),
            withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color,
                             .paragraphStyle: style])
    }

    private static func screenRect(slot: Int, rise: CGFloat) -> CGRect {
        let xs: [CGFloat] = [675, 410, 970, 410, 675, 970]
        let upper = slot >= 3
        return CGRect(x: xs[slot], y: (upper ? 718 : 545) + rise,
                      width: slot == 0 || slot == 4 ? 280 : 250, height: upper ? 136 : 176)
    }
    private static func monitorMount(_ c: CGContext, slot: Int, rise: CGFloat) {
        let r = screenRect(slot: slot, rise: rise)
        c.saveGState(); c.setShouldAntialias(false)
        let center = r.midX.rounded()
        if slot >= 3 {
            block(c, CGRect(x: center - 8, y: 515 + rise, width: 16, height: r.minY - 515 - rise), tint(0x242C2D))
            block(c, CGRect(x: center - 4, y: 518 + rise, width: 4, height: r.minY - 518 - rise), tint(0x768078))
        } else {
            // A visible neck, stepped foot and contact shadow sit on the bare
            // strip at the back of the desk, above the books and keyboard.
            block(c, CGRect(x: center - 43, y: 501 + rise, width: 86, height: 5), tint(0x4C2D1F, alpha: 0.65))
            block(c, CGRect(x: center - 11, y: 511 + rise, width: 22, height: 24), tint(0x252C2C))
            block(c, CGRect(x: center - 7, y: 514 + rise, width: 6, height: 21), tint(0x77837B))
            block(c, CGRect(x: center + 6, y: 514 + rise, width: 3, height: 19), tint(0x414B48))
            block(c, CGRect(x: center - 28, y: 508 + rise, width: 56, height: 8), tint(0x252C2C))
            block(c, CGRect(x: center - 38, y: 504 + rise, width: 76, height: 8), tint(0x252C2C))
            block(c, CGRect(x: center - 32, y: 509 + rise, width: 64, height: 3), tint(0x899185))
            block(c, CGRect(x: center - 32, y: 506 + rise, width: 64, height: 3), tint(0x4C5853))
        }
        c.restoreGState()
    }
    @discardableResult
    private static func monitorShell(_ c: CGContext, slot: Int, rise: CGFloat) -> CGRect {
        let r = screenRect(slot: slot, rise: rise)
        c.saveGState(); c.setShouldAntialias(false)
        let shell = CGRect(x: r.minX - 6, y: r.minY - 16, width: r.width + 12, height: r.height + 22)
        // Chunky, stepped pixel casing. The wider bottom bezel reads as a
        // physical monitor even when task content fills the entire glass.
        block(c, shell.insetBy(dx: 4, dy: 0), tint(0x20282A))
        block(c, shell.insetBy(dx: 0, dy: 4), tint(0x20282A))
        block(c, shell.insetBy(dx: 4, dy: 4), tint(0x48534F))
        block(c, CGRect(x: shell.minX + 7, y: shell.maxY - 6, width: shell.width - 14, height: 2), tint(0xA49A7A))
        block(c, CGRect(x: shell.minX + 4, y: shell.minY + 7, width: 3, height: shell.height - 15), tint(0x778177))
        block(c, CGRect(x: shell.maxX - 7, y: shell.minY + 4, width: 3, height: shell.height - 11), tint(0x303A39))
        panel(c, r, edge: tint(0x151F24), fill: tint(0x768273), border: 4)
        panel(c, r.insetBy(dx: 6, dy: 6), edge: tint(0x071F27), fill: tint(0x102F32), border: 2)
        block(c, CGRect(x: r.minX + 5, y: r.minY - 12, width: r.width - 10, height: 9), tint(0x35413E))
        block(c, CGRect(x: r.midX - 9, y: r.minY - 9, width: 18, height: 3), tint(0x8A927F))
        for offset: CGFloat in [20, 27, 34] {
            block(c, CGRect(x: r.maxX - offset, y: r.minY - 9, width: 3, height: 2), tint(0x7E8A7D))
        }
        block(c, CGRect(x: r.maxX - 12, y: r.minY - 10, width: 4, height: 4), tint(0x9BD89F))
        block(c, CGRect(x: r.minX + 12, y: r.maxY - 42, width: r.width - 24, height: 1), tint(0x365D54))
        c.restoreGState()
        return r
    }

    private static func monitor(_ c: CGContext, task: WorkplaceTask, snapshot: SceneSnapshot, rise: CGFloat, time: TimeInterval) {
        let live = snapshot.taskOrigin?.isLive == true, agent = snapshot.taskOrigin?.agentName ?? "Codex"
        let r = monitorShell(c, slot: task.slot, rise: rise)
        let upper = task.slot >= 3
        let fresh = snapshot.isFresh()
        let status: String = fresh ? task.activityTitle : "已离线"
        let statusColor: NSColor = !fresh || task.status == .idle ? tint(0xA5A894) : task.status == .running ? tint(0x75D999)
            : task.status == .waiting ? waitingGlow : task.status == .failed ? tint(0xF2A083) : tint(0x9ED7AD)
        block(c, CGRect(x: r.minX + 15, y: r.maxY - 29, width: 7, height: 7), statusColor)
        label(String(format: "会话 %02d", task.slot + 1), at: CGPoint(x: r.minX + 29, y: r.maxY - 34), size: 11, color: glow, weight: .medium, width: 80)
        label(status, at: CGPoint(x: r.maxX - 84, y: r.maxY - 34), size: 11, color: statusColor, weight: .medium, width: 73)
        label(task.title, at: CGPoint(x: r.minX + 15, y: r.maxY - 72), size: upper ? 15 : 18, color: tint(0xE1EACB), weight: .semibold, width: r.width - 30)
        if live {
            executionContent(c, task: task, snapshot: snapshot, screen: r, upper: upper, fresh: fresh, accent: statusColor)
            block(c, CGRect(x: r.maxX - 11, y: r.minY + 3, width: 3, height: 3), statusColor)
            return
        }
        let detail = fresh ? (task.currentStep ?? (task.status == .running ? "任务正在进行" : task.status == .waiting ? "等待你确认后继续" : task.status == .failed ? "需要处理后继续" : "任务已完成")) : "打开主应用即可恢复连接"
        label(detail, at: CGPoint(x: r.minX + 15, y: r.maxY - (upper ? 91 : 100)), size: 11, color: tint(0xABC5AC), width: r.width - 30)
        if !upper, fresh, let next = task.nextStep {
            label("下一步：\(next)", at: CGPoint(x: r.minX + 15, y: r.minY + 61), size: 10, color: tint(0x799D8A), width: r.width - 30)
        }
        if let progress = task.progress {
            let bar = CGRect(x: r.minX + 15, y: r.minY + (upper ? 24 : 46), width: r.width - 77, height: 7)
            block(c, bar, tint(0x315451))
            if fresh { block(c, CGRect(x: bar.minX, y: bar.minY, width: bar.width * CGFloat(progress), height: bar.height), statusColor) }
            label(fresh ? "\(Int(progress * 100))%" : "暂停", at: CGPoint(x: bar.maxX + 9, y: bar.minY - 5), size: 11, color: statusColor, width: 46)
        } else {
            let unknownProgress = !fresh ? "进度：已暂停" : task.status == .completed ? "任务已完成"
                : task.status == .waiting ? "等待确认" : task.status == .failed ? "需要处理" : task.status == .idle ? "等待下一项指令" : "进度：进行中"
            label(unknownProgress, at: CGPoint(x: r.minX + 15, y: r.minY + (upper ? 19 : 42)), size: 11, color: statusColor, width: r.width - 30)
        }
        if !upper {
            let elapsed: String
            if task.status == .completed { elapsed = "任务已完成" }
            else if task.status == .idle { elapsed = "会话待机" }
            else if let started = task.startedAt {
                let seconds = max(0, Int(snapshot.updatedAt.timeIntervalSince(started)))
                elapsed = String(format: "已运行 %02d:%02d", seconds / 60, seconds % 60)
            } else { elapsed = live ? "\(agent) 实时会话" : "模拟 Codex 会话" }
            label(elapsed, at: CGPoint(x: r.minX + 15, y: r.minY + 15), size: 10, color: tint(0x7F9E8D), width: r.width - 30)
        }
        block(c, CGRect(x: r.maxX - 11, y: r.minY + 3, width: 3, height: 3), statusColor)
    }

    /// Live details occupy their own rows. A recent message describes what was
    /// said, never a fabricated next step or a percentage of unfinished work.
    private static func executionContent(_ c: CGContext, task: WorkplaceTask, snapshot: SceneSnapshot,
                                         screen r: CGRect, upper: Bool, fresh: Bool, accent: NSColor) {
        let details = task.executionDetails
        let agent = snapshot.taskOrigin?.agentName ?? "Codex"
        let action: String
        if !fresh { action = "状态未知 · 已断开连接" }
        else if task.status == .running, details?.phase == .tool, let tool = details?.toolName {
            action = "工具 · \(tool)"
        } else {
            switch task.status {
            case .running: action = details?.phase == .thinking ? "\(agent) 正在思考" : "\(agent) 正在执行任务"
            case .waiting: action = "等待你在 \(agent) 中确认"
            case .failed: action = "需要你在 \(agent) 中处理"
            case .completed: action = "本轮任务已完成"
            case .idle: action = "等待下一项指令"
            }
        }
        label(action, at: CGPoint(x: r.minX + 15, y: r.minY + (upper ? 47 : 79)),
              size: upper ? 9.5 : 11, color: accent, width: r.width - 30)

        let update = fresh ? details?.latestUpdate : nil
        let recent = update.map { "最近更新：\($0)" }
            ?? (fresh ? "等待本轮可见进展" : "打开主应用即可恢复连接")
        let bodySize: CGFloat = upper ? 9 : 11
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.minimumLineHeight = bodySize * 1.3
        paragraph.maximumLineHeight = bodySize * 1.3
        (recent as NSString).draw(with: CGRect(x: r.minX + 15, y: r.minY + (upper ? 21 : 39),
                                              width: r.width - 30, height: upper ? 24 : 31),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            attributes: [.font: NSFont.systemFont(ofSize: bodySize),
                         .foregroundColor: tint(update == nil ? 0x799D8A : 0xC7D7BB),
                         .paragraphStyle: paragraph])

        let elapsed: String
        if !fresh { elapsed = "已暂停同步" }
        else if task.status == .completed { elapsed = "本轮已完成" }
        else if task.status == .idle { elapsed = "会话待机" }
        else if let started = task.startedAt {
            let seconds = max(0, Int(snapshot.updatedAt.timeIntervalSince(started)))
            elapsed = String(format: "本轮 %02d:%02d", seconds / 60, seconds % 60)
        } else { elapsed = "实时同步" }
        label("\(task.sourceLabel) · \(elapsed)", at: CGPoint(x: r.minX + 15, y: r.minY + (upper ? 5 : 15)),
              size: upper ? 8 : 10, color: tint(0x7F9E8D), width: r.width - 30)
    }

    private static func overviewMonitor(_ c: CGContext, slot: Int, snapshot: SceneSnapshot, rise: CGFloat) {
        let live = snapshot.taskOrigin?.isLive == true, agent = snapshot.taskOrigin?.agentName ?? "Codex"
        let r = monitorShell(c, slot: slot, rise: rise)
        let fresh = snapshot.isFresh()
        let accent = fresh ? tint(0x89C6A1) : tint(0x95A18E)
        let title = slot == 1 ? "会话列表" : slot == 2 ? "需要你处理" : "当前任务"
        block(c, CGRect(x: r.minX + 15, y: r.maxY - 29, width: 7, height: 7), accent)
        label(title, at: CGPoint(x: r.minX + 29, y: r.maxY - 34), size: 13, color: glow, weight: .semibold, width: r.width - 45)
        if !fresh {
            label("工位已离线", at: CGPoint(x: r.minX + 15, y: r.maxY - 75), size: 19, color: accent, weight: .medium, width: r.width - 30)
            label("打开主应用后恢复任务同步", at: CGPoint(x: r.minX + 15, y: r.minY + 43), size: 11, color: tint(0x8DAA97), width: r.width - 30)
        } else if slot == 1 {
            let tasks = snapshot.tasks.sorted { $0.slot < $1.slot }
            if tasks.isEmpty {
                label(live ? "暂无运行会话" : "暂无会话", at: CGPoint(x: r.minX + 15, y: r.maxY - 76), size: 18, color: accent, width: r.width - 30)
                label(live ? "\(agent) 开工后在这里同步" : "添加任务后，屏幕会亮起进展", at: CGPoint(x: r.minX + 15, y: r.minY + 43), size: 11, color: tint(0xA6BDA4), width: r.width - 30)
            } else {
                for (index, task) in tasks.prefix(3).enumerated() {
                    let y = r.maxY - 74 - CGFloat(index) * 27
                    label(task.title, at: CGPoint(x: r.minX + 15, y: y), size: 12, color: tint(0xD0DFC7), width: r.width - 93)
                    label(task.activityTitle, at: CGPoint(x: r.maxX - 76, y: y), size: 10, color: accent, width: 65)
                }
            }
        } else if slot == 2 {
            let waiting = snapshot.tasks.filter { $0.status == .waiting || $0.status == .failed }
            let attentionColor = waiting.first?.status == .failed ? tint(0xF2A083) : waitingGlow
            label(waiting.isEmpty ? "暂时没有待处理事项" : "\(waiting.count) 项需要你处理", at: CGPoint(x: r.minX + 15, y: r.maxY - 77), size: 16, color: waiting.isEmpty ? accent : attentionColor, weight: .medium, width: r.width - 30)
            if let task = waiting.first {
                label(task.title, at: CGPoint(x: r.minX + 15, y: r.minY + 57), size: 12, color: glow, width: r.width - 30)
                label(task.status.title, at: CGPoint(x: r.minX + 15, y: r.minY + 27), size: 11, color: attentionColor, width: r.width - 30)
            } else {
                label("进行中的会话：\(snapshot.tasks.filter { $0.status == .running }.count)", at: CGPoint(x: r.minX + 15, y: r.minY + 43), size: 12, color: tint(0xA6BDA4), width: r.width - 30)
            }
        } else {
            label("工位待机", at: CGPoint(x: r.minX + 15, y: r.maxY - 77), size: 20, color: accent, weight: .medium, width: r.width - 30)
            label(live ? "等待 \(agent) 的真实任务" : "添加会话后，在这里显示任务", at: CGPoint(x: r.minX + 15, y: r.minY + 43), size: 12, color: tint(0xA6BDA4), width: r.width - 30)
        }
        block(c, CGRect(x: r.maxX - 11, y: r.minY + 3, width: 3, height: 3), accent)
    }

    private static func deskBase(_ c: CGContext, rise: CGFloat) {
        c.saveGState(); c.setShouldAntialias(false)
        // Drawer units stay grounded while the tabletop and lift columns rise.
        for x: CGFloat in [425, 1113] {
            panel(c, CGRect(x: x, y: 275, width: 155, height: 143), edge: tint(0x4D2D1B), fill: tint(0x92511E), border: 6)
            for row in 0..<3 {
                let y = CGFloat(285 + row * 42)
                panel(c, CGRect(x: x + 10, y: y, width: 135, height: 36), edge: tint(0x713D1A), fill: tint(0xBD792C), border: 3)
                block(c, CGRect(x: x + 14, y: y + 28, width: 127, height: 3), tint(0xD6973E))
                block(c, CGRect(x: x + 58, y: y + 15, width: 23, height: 5), tint(0x5F401F))
                block(c, CGRect(x: x + 60, y: y + 18, width: 18, height: 2), tint(0xE0BC60))
                block(c, CGRect(x: x + 13, y: y + 4, width: 129, height: 3), tint(0x925322))
                for grain in 0..<12 {
                    let gx = x + 17 + CGFloat((grain * 23 + row * 11) % 106)
                    let gy = y + 7 + CGFloat((grain * 7 + row * 3) % 18)
                    block(c, CGRect(x: gx, y: gy, width: CGFloat(5 + grain % 11), height: 1), tint(grain % 3 == 0 ? 0xDF9D44 : 0x995A23, alpha: 0.45))
                }
            }
            block(c, CGRect(x: x + 19, y: 415, width: 14, height: rise + 9), tint(0x444B3E))
            block(c, CGRect(x: x + 22, y: 416, width: 5, height: rise + 9), tint(0x9B9D78))
        }
        block(c, CGRect(x: 580, y: 376 + rise, width: 533, height: 33), tint(0x6C3C1F))
        block(c, CGRect(x: 585, y: 400 + rise, width: 524, height: 5), tint(0xB16F2C))
        c.restoreGState()
    }
    private static func desktop(_ c: CGContext, rise: CGFloat) {
        if let top = RoomAssets.desktop {
            let width: CGFloat = 900
            // The flat plate has a fixed logical height: props above its back
            // edge cannot rescale the keyboard away from the animated hands.
            let height: CGFloat = RoomAssets.usesFlatForeground ? 128
                : width * CGFloat(top.height) / CGFloat(top.width)
            c.draw(top, in: CGRect(x: 400, y: 402 + rise, width: width, height: height))
        } else {
            panel(c, CGRect(x: 400, y: 402 + rise, width: 900, height: 89), edge: tint(0x62391F), fill: tint(0xD39441), border: 6)
        }
    }
    private static func inputDevices(_ c: CGContext, rise: CGFloat, motion: WorkInputMotion) {
        c.saveGState(); c.setShouldAntialias(false)
        // A small pixel mouse mat covers the old fixed mouse in the tabletop
        // plate, so the moving mouse never leaves a second copy underneath.
        if RoomAssets.usesFlatForeground {
            // The flat game map keeps depth edges parallel. The mouse and
            // hands retain their existing anchors on this rectangular pad.
            block(c, CGRect(x: 924, y: 435 + rise, width: 86, height: 50), tint(0x243A31))
        } else {
            let mat = CGMutablePath()
            mat.move(to: CGPoint(x: 924, y: 435 + rise))
            mat.addLine(to: CGPoint(x: 1010, y: 435 + rise))
            mat.addLine(to: CGPoint(x: 1004, y: 485 + rise))
            mat.addLine(to: CGPoint(x: 930, y: 485 + rise))
            mat.closeSubpath()
            c.addPath(mat); c.setFillColor(tint(0x243A31).cgColor); c.fillPath()
        }
        block(c, CGRect(x: 930, y: 439 + rise, width: 74, height: 39), tint(0x405846))
        block(c, CGRect(x: 932, y: 478 + rise, width: 70, height: 2), tint(0x829071))
        block(c, CGRect(x: 928, y: 436 + rise, width: 78, height: 3), tint(0x1D322C))

        let x = (950 + motion.mouseOffset.x).rounded() - 12
        let y = (459 + rise + motion.mouseOffset.y).rounded() - 17
        block(c, CGRect(x: x + 4, y: y - 2, width: 23, height: 5), tint(0x1B2E29, alpha: 0.55))
        block(c, CGRect(x: x + 3, y: y, width: 18, height: 34), tint(0x1C242A))
        block(c, CGRect(x: x, y: y + 5, width: 24, height: 23), tint(0x1C242A))
        block(c, CGRect(x: x + 3, y: y + 5, width: 18, height: 25), tint(0x4C555D))
        block(c, CGRect(x: x + 5, y: y + 7, width: 4, height: 20), tint(0x7E837F))
        block(c, CGRect(x: x + 17, y: y + 7, width: 3, height: 19), tint(0x353F49))
        let down: CGFloat = motion.click > 0.35 ? 1 : 0
        block(c, CGRect(x: x + 4, y: y + 21 - down, width: 7, height: 9), tint(down > 0 ? 0x454D51 : 0x929890))
        block(c, CGRect(x: x + 13, y: y + 21, width: 7, height: 9), tint(0x626D70))
        block(c, CGRect(x: x + 11, y: y + 21, width: 2, height: 9), tint(0x273139))
        block(c, CGRect(x: x + 10, y: y + 23, width: 4, height: 6), tint(0xB1AD8E))
        block(c, CGRect(x: x + 4, y: y + 4, width: 15, height: 2), tint(0x303C43))

        // Subtle pressed caps sit beneath the animated fingers on the existing
        // keyboard, rather than replacing its authored pixel detail.
        if motion.leftPress > 0.35 {
            block(c, CGRect(x: 777, y: 465 + rise, width: 7, height: 3), tint(0xC3D6AC, alpha: 0.7))
        }
        if motion.rightPress > 0.35 {
            block(c, CGRect(x: 889, y: 463 + rise, width: 7, height: 3), tint(0xC3D6AC, alpha: 0.7))
        }
        c.restoreGState()
    }
    private static func chair(_ c: CGContext, standing: CGFloat) {
        let x = (835 + 260 * standing).rounded(), y: CGFloat = 285
        c.saveGState(); c.setShouldAntialias(false)
        block(c, CGRect(x: x - 7, y: y + 8, width: 14, height: 62), tint(0x354237))
        block(c, CGRect(x: x - 55, y: y + 2, width: 110, height: 10), tint(0x3C4539))
        block(c, CGRect(x: x - 14, y: y - 9, width: 28, height: 12), tint(0x313B32))
        block(c, CGRect(x: x - 58, y: y - 1, width: 15, height: 11), tint(0x2C352D))
        block(c, CGRect(x: x + 43, y: y - 1, width: 15, height: 11), tint(0x2C352D))
        panel(c, CGRect(x: x - 61, y: y + 53, width: 122, height: 19), edge: tint(0x61441F), fill: tint(0x8D6A36))
        panel(c, CGRect(x: x - 59, y: y + 70, width: 118, height: 72), edge: tint(0x78471F), fill: tint(0xBA7C30), border: 5)
        panel(c, CGRect(x: x - 49, y: y + 78, width: 98, height: 58), edge: tint(0x344C3C), fill: tint(0x5A7860), border: 4)
        block(c, CGRect(x: x - 42, y: y + 126, width: 85, height: 4), tint(0x879A71))
        c.restoreGState()
    }

    private static func wallBoard(_ c: CGContext, snapshot: SceneSnapshot) {
        let now = Date()
        c.saveGState()
        if RoomAssets.usesFlatForeground { c.translateBy(x: 45, y: 0) }
        // All content is anchored to the painted board's inner paper area.
        // Measuring glyph ink avoids the different Chinese/digit font metrics
        // moving the numbers above their labels or the title into the frame.
        c.clip(to: CGRect(x: 1235, y: 696, width: 175, height: 173))
        boardText("今日进展", in: c, rect: CGRect(x: 1240, y: 832, width: 166, height: 31),
                  size: 22, weight: .semibold, alignment: .center)
        block(c, CGRect(x: 1245, y: 826, width: 155, height: 1), tint(0xAD783C, alpha: 0.4))
        let entries = SceneReadouts.todayProgress(snapshot, at: now)
        let colors = [tint(0x419F61), tint(0x3D6FA2), tint(0xB95736), tint(0x5D8760)]
        for (index, entry) in entries.enumerated() {
            let centerY: CGFloat = 806 - CGFloat(index) * 30
            let rowInk = index == 1 ? tint(0x284D78) : ink
            block(c, CGRect(x: 1245, y: centerY - 4, width: 9, height: 9), colors[index])
            boardText(entry.label, in: c, rect: CGRect(x: 1263, y: centerY - 13, width: 104, height: 26), size: 16, color: rowInk)
            boardText(String(entry.count), in: c, rect: CGRect(x: 1370, y: centerY - 13, width: 30, height: 26),
                      size: 18, color: rowInk, weight: .medium, alignment: .right)
        }
        c.restoreGState()
    }

    private static func boardText(_ text: String, in c: CGContext, rect: CGRect, size: CGFloat,
                                  color: NSColor? = nil, weight: NSFont.Weight = .regular, alignment: NSTextAlignment = .left) {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight),
                                                       .foregroundColor: color ?? ink]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let glyphs = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
        c.saveGState()
        c.clip(to: rect)
        c.textMatrix = .identity
        let availableScale = min(1, rect.width / max(1, glyphs.width))
        let width = glyphs.width * availableScale
        let startX = alignment == .right ? rect.maxX - width : alignment == .center ? rect.midX - width / 2 : rect.minX
        c.translateBy(x: startX, y: rect.midY)
        c.scaleBy(x: availableScale, y: availableScale)
        c.textPosition = CGPoint(x: -glyphs.minX, y: -glyphs.midY)
        CTLineDraw(line, c)
        c.restoreGState()
    }
    /// The painted clock can be partially cropped on a 16:10 display. Keep
    /// its text inside the remaining paper rather than imposing a minimum
    /// width that extends off-screen.
    static func clockContentRect(visibleRect: CGRect) -> CGRect {
        let preferredLeft: CGFloat = RoomAssets.usesFlatForeground ? 1512 : 1480
        let minimumLeft: CGFloat = RoomAssets.usesFlatForeground ? 1504 : 1472
        let preferredWidth: CGFloat = RoomAssets.usesFlatForeground ? 128 : 148
        let right = min(preferredLeft + preferredWidth, visibleRect.maxX - 12)
        guard right > minimumLeft else { return .zero }
        let left = min(preferredLeft, max(minimumLeft, right - preferredWidth))
        return CGRect(x: left, y: 828, width: right - left, height: 49)
    }

    private static func clock(_ c: CGContext, visibleRect: CGRect, at now: Date) {
        let content = clockContentRect(visibleRect: visibleRect)
        guard !content.isEmpty else { return }
        let width = content.width
        let dateText: String
        if width < 125 {
            let components = Calendar.current.dateComponents([.month, .day], from: now)
            dateText = "\(components.month ?? 1)月\(components.day ?? 1)日"
        } else { dateText = SceneReadouts.dateText(at: now) }
        boardText(dateText, in: c, rect: CGRect(x:content.minX,y:854,width:width,height:23),
                  size: width < 125 ? 11 : 14)
        boardText(SceneReadouts.timeText(at: now), in: c,
                  rect: CGRect(x:content.minX,y:828,width:width,height:36), size:33, weight:.semibold)
    }
    private static func statusPlaque(_ c: CGContext, snapshot: SceneSnapshot, actionTitle: String? = nil) {
        let live = snapshot.taskOrigin?.isLive == true, agent = snapshot.taskOrigin?.agentName ?? "Codex"
        let r = CGRect(x: 585, y: 32, width: 516, height: 35)
        panel(c, r, edge: tint(0x54371F, alpha: 0.8), fill: tint(0xE9C180, alpha: 0.94), border: 3)
        let status: String
        if let title = actionTitle { status = "\(title) · 小憩片刻，任务状态照常同步" }
        else if !snapshot.isFresh() { status = live ? "\(agent) 未连接 · 分身休息中" : "工位离线 · 分身休息中" }
        else if snapshot.demoRunning { status = "模拟演示 · 每 60 秒循环 · 菜单栏可返回控制台" }
        else if live {
            let total = snapshot.totalSessionCount ?? snapshot.tasks.count
            let overflow = total > 6 ? " · 展示前 6 个" : ""
            status = "\(agent) · \(total) 个会话\(overflow) · \(snapshot.resolvedPose() == .slacking ? "休息中" : snapshot.resolvedPose() == .standing ? "站着打工" : "坐着打工")"
        }
        else if snapshot.resolvedPose() == .slacking { status = "摸鱼时间 · 分身正在床上睡觉" }
        else { status = "模拟 Codex · \(snapshot.tasks.count) 个会话 · \(snapshot.resolvedPose() == .standing ? "站着打工" : "坐着打工")" }
        label(status, at: CGPoint(x: r.minX + 14, y: r.minY + 8), size: 12, color: ink, weight: .medium, width: r.width - 28)
    }
    private static func fallbackRoom(_ c: CGContext) {
        block(c, CGRect(origin: .zero, size: size), tint(0xCC994F))
        block(c, CGRect(x: 0, y: 0, width: size.width, height: 430), tint(0x99612F))
        for y in stride(from: 20, to: 430, by: 44) {
            block(c, CGRect(x: 0, y: y, width: 1672, height: 3), tint(0x704522))
        }
    }
}
