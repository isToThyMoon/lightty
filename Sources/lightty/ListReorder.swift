import AppKit

/// 手动拖拽重排的共用机件（任务列表 / 标签页 pane 行共用，保证两处手感一致）。
///
/// 为什么不用 NSDraggingSession：它把行渲染成一张“脱手”的拖拽图，位置由拖拽
/// 服务器按自己的节拍更新，跟手有可感的延迟，起手还有一段“跳到光标上方再吸附”
/// 的位移——正是用户反馈的卡顿来源。这里改成自建事件循环：每个 mouseDragged
/// 直接把快照浮层的 frame 跟到光标，零延迟 1:1 跟手；空位由调用方用带动画的
/// 行移动（moveRow / 排列变更）现场让出。
enum ReorderDrag {
    /// 抬起态的浮层快照。轻微放大 + 阴影 = “拿起来”的手感，不喧宾夺主。
    static func makeSnapshot(_ image: NSImage, frame: NSRect) -> NSView {
        let host = NSView(frame: frame)
        host.wantsLayer = true
        let iv = NSImageView(frame: host.bounds)
        iv.image = image
        iv.imageScaling = .scaleAxesIndependently
        iv.autoresizingMask = [.width, .height]
        host.addSubview(iv)
        host.shadow = {
            let s = NSShadow()
            s.shadowColor = NSColor.black.withAlphaComponent(0.28)
            s.shadowBlurRadius = 10
            s.shadowOffset = NSSize(width: 0, height: -2)
            return s
        }()
        host.layer?.transform = CATransform3DMakeScale(1.03, 1.03, 1)
        return host
    }

    /// 一行的位图快照。
    static func snapshot(of view: NSView) -> NSImage? {
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0,
              let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        view.cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        return image
    }

    /// 跑一整段拖拽：从 `startEvent`（已越过阈值的那次 dragged）起自建循环。
    /// - host: 浮层所在坐标系（也是光标换算的参照）。
    /// - snapshotView: 已经 addSubview 到 host 的浮层，起始 frame 已摆好。
    /// - grabOffsetY: 光标在被抓行内的 y 偏移（host 坐标），跟手时保持不变。
    /// - onMove: 每次移动回调当前光标（host 坐标），调用方据此现场让位。
    /// - dropFrame: 释放时浮层要归位到的目标 frame（host 坐标）；nil 则原地淡出。
    /// - onCommit: 释放后落定（在归位动画开始前调用，用于提交模型/持久化）。
    /// - onEnd: 收尾（浮层已移除），用于 reload / 复原隐藏行。
    static func run(
        host: NSView,
        snapshotView: NSView,
        startEvent: NSEvent,
        grabOffsetY: CGFloat,
        onMove: @escaping (_ cursorInHost: NSPoint) -> Void,
        dropFrame: @escaping () -> NSRect?,
        onCommit: @escaping () -> Void,
        onEnd: @escaping () -> Void
    ) {
        func cursor(_ e: NSEvent) -> NSPoint { host.convert(e.locationInWindow, from: nil) }

        func follow(_ e: NSEvent) {
            let c = cursor(e)
            var f = snapshotView.frame
            f.origin.y = c.y - grabOffsetY
            // 夹在 host 内，避免拖出可视区后浮层消失得莫名其妙
            f.origin.y = min(max(f.origin.y, host.bounds.minY), host.bounds.maxY - f.height)
            snapshotView.frame = f
            onMove(c)
        }

        follow(startEvent)

        let mask: NSEvent.EventTypeMask = [.leftMouseDragged, .leftMouseUp]
        while let e = NSApp.nextEvent(
            matching: mask, until: .distantFuture, inMode: .eventTracking, dequeue: true
        ) {
            if e.type == .leftMouseUp { break }
            follow(e)
        }

        onCommit()

        let finish = {
            snapshotView.removeFromSuperview()
            onEnd()
        }
        if let target = dropFrame() {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.16
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                snapshotView.animator().frame = target
                (snapshotView.animator() as? NSView)?.layer?.transform = CATransform3DIdentity
            }, completionHandler: finish)
        } else {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.12
                snapshotView.animator().alphaValue = 0
            }, completionHandler: finish)
        }
    }
}

/// 支持“跟手”重排的 NSTableView：自建拖拽循环，快照浮层 1:1 跟随光标，
/// 空位用 moveRow 现场让出。单击/双击原样透传给外部处理（拖拽只在越过
/// 阈值后接管，否则当作点击）。
final class ReorderingTableView: NSTableView {
    /// 是否允许重排（过滤/搜索态下展示序≠真实序，禁止）。
    var canReorder: () -> Bool = { true }
    /// 越过阈值、进入拖拽时逐帧调用：把第 from 行移到第 to 行（模型 + 视图同步）。
    var previewMove: ((_ from: Int, _ to: Int) -> Void)?
    /// 释放落定：最终把 from 落到 to（此刻模型已随 preview 同步，通常只需持久化 + reload）。
    var commitReorder: ((_ finalIndex: Int) -> Void)?
    /// 非拖拽单击。
    var onRowClick: ((_ row: Int) -> Void)?
    /// 非拖拽双击。
    var onRowDoubleClick: ((_ row: Int) -> Void)?

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        guard row >= 0 else { super.mouseDown(with: event); return }

        if event.clickCount == 2 {
            onRowDoubleClick?(row)
            return
        }

        // 阈值前先探一段：没越过 = 点击，越过 = 接管为拖拽。
        let startInWindow = event.locationInWindow
        let mask: NSEvent.EventTypeMask = [.leftMouseDragged, .leftMouseUp]
        while let e = NSApp.nextEvent(
            matching: mask, until: .distantFuture, inMode: .eventTracking, dequeue: true
        ) {
            switch e.type {
            case .leftMouseUp:
                onRowClick?(row)
                return
            case .leftMouseDragged:
                let dy = e.locationInWindow.y - startInWindow.y
                let dx = e.locationInWindow.x - startInWindow.x
                guard hypot(dx, dy) >= 4, canReorder() else { continue }
                beginReorder(row: row, firstDrag: e)
                return
            default:
                continue
            }
        }
    }

    private func beginReorder(row: Int, firstDrag: NSEvent) {
        guard let rowView = self.rowView(atRow: row, makeIfNecessary: false),
              let image = ReorderDrag.snapshot(of: rowView) else { return }

        let startFrame = rect(ofRow: row)
        let snap = ReorderDrag.makeSnapshot(image, frame: startFrame)
        addSubview(snap)
        rowView.alphaValue = 0  // 真行隐身，浮层代它出镜

        let cursorInSelf = convert(firstDrag.locationInWindow, from: nil)
        let grabOffsetY = cursorInSelf.y - startFrame.minY

        var current = row

        ReorderDrag.run(
            host: self,
            snapshotView: snap,
            startEvent: firstDrag,
            grabOffsetY: grabOffsetY,
            onMove: { [weak self] c in
                guard let self else { return }
                var target = self.row(at: c)
                if target < 0 { target = self.numberOfRows - 1 }
                guard target != current, target >= 0 else { return }
                self.previewMove?(current, target)
                self.moveRow(at: current, to: target)
                current = target
            },
            dropFrame: { [weak self] in self?.rect(ofRow: current) },
            onCommit: { [weak self] in self?.commitReorder?(current) },
            onEnd: { [weak rowView] in rowView?.alphaValue = 1 }
        )
    }
}
