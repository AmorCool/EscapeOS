//
//  SSHDebugView.swift
//  EscapeSpace
//
//  SSH 无线调试页（更多 → SSH 调试）：
//  展示连接命令/凭据、启停服务、重置密码。
//  电脑侧: ssh escape@<IP> -p 2222，登录后输入 help 查看内置诊断命令。
//

import SwiftUI

struct SSHDebugView: View {
    @StateObject private var service = SSHServerService.shared

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(service.isRunning ? Color.green : Color.secondary)
                            .frame(width: 8, height: 8)
                        Text(service.isRunning ? "服务运行中（局域网可达）" : "服务未启动")
                            .font(.subheadline)
                            .foregroundColor(service.isRunning ? .green : .secondary)
                    }
                    if service.isRunning {
                        Text(service.connectHint)
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundColor(.primary)
                            .textSelection(.enabled)
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("状态")
            }

            Section {
                Button {
                    if service.isRunning {
                        service.stop()
                    } else {
                        service.start()
                    }
                } label: {
                    HStack {
                        Image(systemName: service.isRunning ? "stop.circle.fill" : "play.circle.fill")
                        Text(service.isRunning ? "停止 SSH 服务" : "启动 SSH 服务")
                    }
                }
                .tint(.blue)

                Button {
                    service.resetCredentials()
                } label: {
                    HStack {
                        Image(systemName: "key.horizontal")
                        Text("重置密码")
                    }
                }
                .tint(.orange)
                .disabled(service.isRunning)
            } footer: {
                if service.isRunning {
                    Text("密码重置需先停止服务。连接后输入 help 查看可用诊断命令。")
                } else {
                    Text("启动后，同一局域网内的电脑可通过上方命令无线连接。仅局域网可达，随时可关。")
                }
            }

            Section {
                HStack {
                    Text("端口")
                    Spacer()
                    Text("\(service.port)")
                        .foregroundColor(.secondary)
                        .font(.body.monospacedDigit())
                }
                HStack {
                    Text("用户名")
                    Spacer()
                    Text(service.username)
                        .foregroundColor(.secondary)
                        .font(.body.monospaced())
                }
                HStack {
                    Text("密码")
                    Spacer()
                    Text(service.password)
                        .foregroundColor(.secondary)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                }
                HStack {
                    Text("局域网 IP")
                    Spacer()
                    Text(service.lanIP)
                        .foregroundColor(.secondary)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                }
            } header: {
                Text("连接信息")
            }

            Section {
                Label("受限 shell：不执行系统命令，只应答内置诊断命令（status/logs/modules/ip/uptime/ping）", systemImage: "lock.shield")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                Label("需电脑与手机在同一 Wi-Fi；首次连接触发本地网络权限弹窗，请允许", systemImage: "wifi")
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
        .navigationTitle("SSH 调试")
        .navigationBarTitleDisplayMode(.inline)
    }
}
