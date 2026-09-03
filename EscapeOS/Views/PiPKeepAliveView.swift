//
//  PiPKeepAliveView.swift
//  EscapeSpace
//
//  PiP 保活设置页（更多 → PiP 保活）.
//  说明：playerLayer 必须常驻视图层级（哪怕很小），PiP 才可能启动；
//  页面内嵌一个小预览窗，同时承载 layer.开始 PiP 后可离开应用，
//  系统以悬浮小窗形式保活宿主进程.
//

import SwiftUI
import AVFoundation

struct PiPKeepAliveView: View {
    @StateObject private var service = PiPKeepAliveService.shared
    @StateObject private var highRefresh = HighRefreshService.shared

    var body: some View {
        List {
            Section {
                VStack(spacing: 12) {
                    // playerLayer 宿主（PiP 源视图，必须常驻层级）
                    PlayerLayerHost()
                        .frame(width: 160, height: 90)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                        )

                    HStack(spacing: 6) {
                        Circle()
                            .fill(service.isPiPActive ? Color.green : Color.secondary)
                            .frame(width: 8, height: 8)
                        Text(
                            service.isPiPActive
                                ? (service.isHidden ? "画中画运行中 · 已隐藏（后台保活生效）" : "画中画运行中 · 后台保活生效")
                                : "画中画未启动")
                            .font(.subheadline)
                            .foregroundColor(service.isPiPActive ? .green : .secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            } header: {
                Text("状态")
            }

            Section {
                Button {
                    if service.isPiPActive {
                        service.stop()
                    } else {
                        service.start()
                    }
                } label: {
                    HStack {
                        Image(systemName: service.isPiPActive ? "pip.exit" : "pip.enter")
                        Text(service.isPiPActive ? "停止画中画" : "启动画中画保活")
                        Spacer()
                        if service.isPiPActive, let startedAt = service.startedAt {
                            // 时长源在 Service（跨页面存活），TimelineView 每秒驱动
                            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                                Text(formatElapsed(Int(ctx.date.timeIntervalSince(startedAt))))
                                    .font(.body.monospacedDigit())
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
                .tint(.blue)

                // 隐藏 / 显示（原版 0.1pt 技巧——缩 preferredContentSize 到不可见）
                if service.isPiPActive {
                    Button {
                        if service.isHidden {
                            service.show()
                        } else {
                            service.hide()
                        }
                    } label: {
                        HStack {
                            Image(systemName: service.isHidden ? "eye" : "eye.slash")
                            Text(service.isHidden ? "显示画中画窗口" : "隐藏画中画窗口（保活继续）")
                        }
                    }
                    .tint(.primary)
                }

                // v0.3.59：悬浮窗高度调节（原版 UISlider 方案，修 SwiftUI Slider 闪退）
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("悬浮窗高度")
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(String(format: "%.1f pt", service.pipHeight))
                            .font(.body.monospacedDigit())
                    }
                    PiPHeightSlider(value: Binding(
                        get: { service.pipHeight },
                        set: { service.setHeight($0) }
                    ))
                    .frame(height: 31)
                }
            } footer: {
                Text("启动后回主屏幕或锁屏，系统以悬浮小窗维持应用活跃.悬浮窗支持拖动/双指缩放；「隐藏」会把窗口缩到不可见但保活继续.用于需要长时间后台运行的任务（隧道保活 / 长传输）.")
            }

            Section {
                Label("保活强度：PiP > 静默音频（自动）", systemImage: "shield.lefthalf.filled")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                if let err = service.lastError {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundColor(.red)
                }
            } header: {
                Text("说明")
            }

            // v0.3.51：全局高刷（移植 GlobalRefresh 帧率方案）
            Section {
                Toggle(isOn: Binding(
                    get: { highRefresh.isRunning },
                    set: { $0 ? highRefresh.start() : highRefresh.stop() }
                )) {
                    HStack {
                        Image(systemName: "speedometer")
                        Text("强制 \(highRefresh.maxFPS)Hz 高刷")
                    }
                }
                .tint(.blue)
                HStack {
                    Text("实测帧率")
                        .foregroundColor(.secondary)
                    Spacer()
                Text(highRefresh.isRunning ? "\n(highRefresh.measuredFPS) FPS" : "—")
                        .font(.body.monospacedDigit())
                        .foregroundColor(highRefresh.measuredFPS >= 100 ? .green : .primary)
                }
            } header: {
                Text("全局高刷")
            } footer: {
                Text("开启后本应用活跃期间强制维持设备最高刷新率（\(highRefresh.maxFPS)Hz，CADisplayLink preferredFrameRateRange 方案）.关闭后交还系统自适应.")
            }
        }
        .navigationTitle("PiP 保活")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func formatElapsed(_ s: Int) -> String {
        String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }
}

/// UIViewRepresentable：为 PiP 提供真实窗口层级容器
/// （pipSourceView 由 Service 自己创建/持有/缩放，对齐原版 view.addSubview）
struct PlayerLayerHost: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let host = UIView()
        host.backgroundColor = .black
        DispatchQueue.main.async {
            PiPKeepAliveService.shared.attach(hostContainer: host)
        }
        return host
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}


/// 原版高度滑杆：UISlider（0.1~220 连续，值变化步进 0.1）
/// ——SwiftUI Slider 在本页面拖动即闪退，换 UIKit 控件后稳定
struct PiPHeightSlider: UIViewRepresentable {
    @Binding var value: CGFloat

    func makeUIView(context: Context) -> UISlider {
        let s = UISlider()
        s.minimumValue = 0.1
        s.maximumValue = 220
        s.isContinuous = true
        s.addTarget(context.coordinator, action: #selector(Coordinator.touchDown(_:)), for: .touchDown)
        s.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .valueChanged)
        s.addTarget(context.coordinator, action: #selector(Coordinator.ended(_:)), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        return s
    }

    func updateUIView(_ uiView: UISlider, context: Context) {
        // 拖动中不回写——否则拇指和手指打架（表现：数值瞬间归 0 再跳 0.1）
        guard !context.coordinator.isTracking else { return }
        if abs(uiView.value - Float(value)) > 0.05 {
            uiView.value = Float(value)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject {
        var parent: PiPHeightSlider
        var isTracking = false
        init(_ parent: PiPHeightSlider) { self.parent = parent }

        @objc func touchDown(_ slider: UISlider) { isTracking = true }

        @objc func changed(_ slider: UISlider) {
            let stepped = (max(slider.value, 0.1) / 0.1).rounded() * 0.1
            parent.value = CGFloat(stepped)
        }

        @objc func ended(_ slider: UISlider) { isTracking = false }
    }
}
