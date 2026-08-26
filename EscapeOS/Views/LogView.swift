import SwiftUI

/// 日志板块（参考原版 Erosion 的 LogView 样式）：
/// 等宽字体滚动展示、长按菜单复制/导出、工具栏导出（系统分享面板）与清空。
/// 数据源为 `EscapeLog`（配置管理等操作自动记录）。
struct LogView: View {
    @State private var logText = ""
    @State private var shareTarget: ShareTarget?
    @State private var showClearConfirm = false

    var body: some View {
        GeometryReader { _ in
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    Text(logText.isEmpty ? "暂无日志" : logText)
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .contextMenu {
                            Button {
                                UIPasteboard.general.string = logText
                            } label: {
                                Label("复制日志", systemImage: "doc.on.doc")
                            }
                            Button {
                                exportLogs()
                            } label: {
                                Label("导出日志", systemImage: "square.and.arrow.up")
                            }
                        }
                    Spacer()
                        .id(0)
                }
                .onAppear {
                    refresh()
                }
                .onReceive(NotificationCenter.default.publisher(for: EscapeLog.didChange)) { _ in
                    refresh()
                }
                .onChange(of: logText) { _, _ in
                    withAnimation {
                        proxy.scrollTo(0, anchor: .bottom)
                    }
                }
            }
        }
        .navigationTitle("日志")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button {
                    exportLogs()
                } label: {
                    Label("导出日志", systemImage: "square.and.arrow.up")
                }
                Button {
                    showClearConfirm = true
                } label: {
                    Label("清空日志", systemImage: "trash")
                }
            }
        }
        .alert("清空日志", isPresented: $showClearConfirm) {
            Button("清空", role: .destructive) {
                EscapeLog.shared.clear()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将删除全部日志记录与本地日志文件。")
        }
        .sheet(item: $shareTarget) { target in
            ShareSheet(items: [target.url])
        }
    }

    private func refresh() {
        logText = EscapeLog.shared.output
    }

    private func exportLogs() {
        guard let url = EscapeLog.shared.exportURL() else { return }
        if !FileManager.default.fileExists(atPath: url.path) {
            try? Data().write(to: url)
        }
        shareTarget = ShareTarget(url: url)
    }
}
