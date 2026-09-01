//
//  PiPKeepAliveView.swift
//  EscapeSpace
//
//  PiP 保活设置页（更多 → PiP 保活）。
//  说明：playerLayer 必须常驻视图层级（哪怕很小），PiP 才可能启动；
//  页面内嵌一个小预览窗，同时承载 layer。开始 PiP 后可离开应用，
//  系统以悬浮小窗形式保活宿主进程。
//

import SwiftUI
import AVFoundation

struct PiPKeepAliveView: View {
    @StateObject private var service = PiPKeepAliveService.shared
    @State private var countdown = 0
    @State private var timer: Timer?

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
                        startCountdown()
                    }
                } label: {
                    HStack {
                        Image(systemName: service.isPiPActive ? "pip.exit" : "pip.enter")
                        Text(service.isPiPActive ? "停止画中画" : "启动画中画保活")
                        Spacer()
                        if countdown > 0 && !service.isPiPActive {
                            Text("（\(countdown)s）")
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .tint(.blue)

                // v0.3.50：隐藏 / 显示（原版 0.1pt 技巧——缩 preferredContentSize）
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
                    .tint(.orange)
                }
            } footer: {
                Text("启动后回主屏幕或锁屏，系统以悬浮小窗维持应用活跃。悬浮窗支持拖动/双指缩放；「隐藏」会把窗口缩到不可见但保活继续。用于需要长时间后台运行的任务（隧道保活 / 长传输）。")
            }

            Section {
                Label("保活强度：PiP > 静默音频（自动）", systemImage: "shield.lefthalf.filled")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                Label("首次启动会生成 2 秒循环视频（约 3KB）", systemImage: "film")
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
        }
        .navigationTitle("PiP 保活")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            timer?.invalidate()
            timer = nil
        }
    }

    /// 启动后有 10 秒宽限期：若 PiP 未激活则提示失败
    private func startCountdown() {
        timer?.invalidate()
        countdown = 10
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { t in
            countdown -= 1
            if countdown <= 0 || service.isPiPActive {
                t.invalidate()
                timer = nil
            }
        }
    }
}

/// UIViewRepresentable：承载 AVPlayerLayer（PiP 源视图）
struct PlayerLayerHost: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = .black
        DispatchQueue.main.async {
            PiPKeepAliveService.shared.attach(sourceView: v)
        }
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}
