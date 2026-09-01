import io

def patch(path, old, new, count=1):
    s = io.open(path, encoding='utf-8').read().replace('\r\n', '\n')
    assert s.count(old) == count, (path, old[:60], s.count(old), s.count(old))
    io.open(path, 'w', encoding='utf-8', newline='\n').write(s.replace(old, new))

p = 'EscapeOS/Services/PiPKeepAliveService.swift'

# ① startedAt 进 Service（跨页面存活）+ host/source 双视图
patch(p,
'''    @Published private(set) var isPiPActive = false
    @Published private(set) var isHidden = false
    @Published private(set) var lastError: String?

    private var pipController: AVPictureInPictureController?
    private var contentVC: UIViewController?
    /// 在窗口层级内的源视图（启动 PiP 的前提；PiP 启动后可离开页面）
    private weak var sourceView: UIView?''',
'''    @Published private(set) var isPiPActive = false
    @Published private(set) var isHidden = false
    @Published private(set) var lastError: String?
    /// PiP 启动时刻（页面离开再回来时长不归零的关键——由 TimelineView 实时计算）
    @Published private(set) var startedAt: Date?

    private var pipController: AVPictureInPictureController?
    private var contentVC: UIViewController?
    /// SwiftUI 布局宿主（frame 由 SwiftUI 管）
    private weak var hostView: UIView?
    /// 实际 PiP 源视图（frame 由本服务管——videoCall 模式 PiP 窗口尺寸跟随它）
    private weak var sourceView: UIView?''')

patch(p,
'''    /// 绑定在窗口层级内的宿主视图（页面内的预览小窗即可）
    func attach(sourceView: UIView) {
        self.sourceView = sourceView
    }''',
'''    /// 绑定宿主视图 + 内部源视图（源视图 frame 归本服务控制）
    func attach(host: UIView, sourceView: UIView) {
        self.hostView = host
        self.sourceView = sourceView
        // 恢复上次隐藏态的源视图尺寸
        sourceView.frame = CGRect(origin: .zero,
                                  size: isHidden ? Self.hiddenSize : host.bounds.size)
    }''')

# ② hide：源视图也缩到 1x1 + alpha 三件套
patch(p,
'''    func hide() {
        guard let vc = contentVC else { return }
        UIView.performWithoutAnimation {
            vc.preferredContentSize = Self.hiddenSize
            vc.view.backgroundColor = .clear
            vc.view.layer.backgroundColor = UIColor.clear.cgColor
            vc.view.alpha = 0.01
            vc.view.layoutIfNeeded()
            CATransaction.flush()
        }
        isHidden = true
    }

    func show() {
        guard let vc = contentVC else { return }
        UIView.performWithoutAnimation {
            vc.preferredContentSize = Self.normalSize
            vc.view.alpha = 1
            vc.view.backgroundColor = .black
            vc.view.layoutIfNeeded()
        }
        isHidden = false
    }''',
'''    func hide() {
        guard let vc = contentVC else { return }
        UIView.performWithoutAnimation {
            // videoCall 模式 PiP 窗口尺寸跟随源视图——源视图必须一起缩（原版 minPiPHeight 同理）
            sourceView?.frame.size = Self.hiddenSize
            vc.preferredContentSize = Self.hiddenSize
            vc.view.backgroundColor = .clear
            vc.view.layer.backgroundColor = UIColor.clear.cgColor
            vc.view.alpha = 0.01
            sourceView?.alpha = 0.01
            hostView?.layoutIfNeeded()
            CATransaction.flush()
        }
        isHidden = true
    }

    func show() {
        guard let vc = contentVC else { return }
        UIView.performWithoutAnimation {
            sourceView?.frame.size = hostView?.bounds.size ?? Self.normalSize
            vc.preferredContentSize = Self.normalSize
            vc.view.alpha = 1
            vc.view.backgroundColor = .black
            sourceView?.alpha = 1
            hostView?.layoutIfNeeded()
        }
        isHidden = false
    }''')

# ③ didStart 记 startedAt / didStop 清空
patch(p,
'''    func pictureInPictureControllerDidStartPictureInPicture(_ c: AVPictureInPictureController) {
        DispatchQueue.main.async {
            self.isPiPActive = true
            self.isHidden = false
        }
    }
    func pictureInPictureControllerDidStopPictureInPicture(_ c: AVPictureInPictureController) {
        DispatchQueue.main.async {
            self.isPiPActive = false''',
'''    func pictureInPictureControllerDidStartPictureInPicture(_ c: AVPictureInPictureController) {
        DispatchQueue.main.async {
            self.isPiPActive = true
            self.isHidden = false
            if self.startedAt == nil { self.startedAt = Date() }
        }
    }
    func pictureInPictureControllerDidStopPictureInPicture(_ c: AVPictureInPictureController) {
        DispatchQueue.main.async {
            self.isPiPActive = false
            self.startedAt = nil''')

print('PiP Service 三处修复完成')

# ④ View：TimelineView 算时长（无 @State 归零问题）
p2 = 'EscapeOS/Views/PiPKeepAliveView.swift'

patch(p2,
'''struct PiPKeepAliveView: View {
    @StateObject private var service = PiPKeepAliveService.shared
    @StateObject private var highRefresh = HighRefreshService.shared
    @State private var elapsed = 0
    @State private var elapsedTimer: Timer?''',
'''struct PiPKeepAliveView: View {
    @StateObject private var service = PiPKeepAliveService.shared
    @StateObject private var highRefresh = HighRefreshService.shared''')

patch(p2,
'''                        if service.isPiPActive {
                            Text(formatElapsed(elapsed))
                                .font(.body.monospacedDigit())
                                .foregroundColor(.secondary)
                        }''',
'''                        if service.isPiPActive, let startedAt = service.startedAt {
                            // TimelineView 每秒驱动；时长源在 Service，页面离开回来不归零
                            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                                Text(formatElapsed(Int(ctx.date.timeIntervalSince(startedAt))))
                                    .font(.body.monospacedDigit())
                                    .foregroundColor(.secondary)
                            }
                        }''')

patch(p,
'''    /// 运行时长计时
    private func startCountdown() {
        elapsedTimer?.invalidate()
        elapsed = 0
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { t in
            if service.isPiPActive {
                elapsed += 1
            } else {
                elapsed = 0
                t.invalidate()
                elapsedTimer = nil
            }
        }
    }

''', '')

patch(p2,
'''                        .clipShape(RoundedRectangle(cornerRadius: 10))''',
'''                        .clipShape(RoundedRectangle(cornerRadius: 10))''')

# PlayerLayerHost：host + 内部 source 双视图
patch(p2,
'''struct PlayerLayerHost: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = .black
        DispatchQueue.main.async {
            PiPKeepAliveService.shared.attach(sourceView: v)
        }
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}''',
'''struct PlayerLayerHost: UIViewRepresentable {
    /// 外层 = SwiftUI 布局宿主；内层 = PiP 源视图（frame 归 Service 控制，
    /// 隐藏时缩到 1x1 不会被 SwiftUI 布局覆盖）
    func makeUIView(context: Context) -> UIView {
        let host = UIView()
        host.backgroundColor = .black
        let source = UIView()
        source.backgroundColor = .clear
        source.frame = host.bounds
        source.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.addSubview(source)
        DispatchQueue.main.async {
            PiPKeepAliveService.shared.attach(host: host, sourceView: source)
        }
        return host
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}''')

# onDisappear 清理引用（elapsedTimer 已不存在）
s = io.open(p2, encoding='utf-8').read()
old_dis = '''        .onDisappear {
            elapsedTimer?.invalidate()
            elapsedTimer = nil
        }'''
if old_dis in s:
    s = s.replace(old_dis, '')
    io.open(p2, 'w', encoding='utf-8', newline='\n').write(s)
    print('onDisappear 清理完成')

# 启动按钮里 startCountdown() 调用删掉
patch(p2,
'''                    } else {
                        service.start()
                        startCountdown()
                    }''',
'''                    } else {
                        service.start()
                    }''')

print('④ View 修复完成')
