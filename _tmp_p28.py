import io

def patch(path, old, new, count=1):
    s = io.open(path, encoding='utf-8').read().replace('\r\n', '\n')
    assert s.count(old) == count, (path, old[:60], s.count(old), s.count(old))
    io.open(path, 'w', encoding='utf-8', newline='\n').write(s.replace(old, new))

p = 'EscapeOS/Views/ProcessManagerView.swift'

# ② 日志监控开关：toolbar 加 toggle（memoryWatchEnabled @AppStorage）
patch(p,
'''struct ProcessManagerView: View {
    @State private var showLogViewer = false''',
'''struct ProcessManagerView: View {
    @State private var showLogViewer = false
    /// v0.3.45：内存监控开关——关闭后 refresh 不再触发 sysmontap 查询
    @AppStorage("ProcessMemoryWatch") private var memoryWatchEnabled = true''')

# refresh 里调用 fetchMemoryAsync 前检查开关
patch(p,
'''                // 内存异步后补（不阻塞刷新流程）
                self?.fetchMemoryAsync()''',
'''                // 内存异步后补（不阻塞刷新流程；受监控开关控制）
                if self?.memoryWatchEnabled == true {
                    self?.fetchMemoryAsync()
                }''')

# toolbar 加开关按钮（toggle 图标 + 状态显示）
patch(p,
'''        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showLogViewer = true
                } label: {
                    Image(systemName: "doc.text.magnifyingglass")
                }
                .accessibilityLabel("查看诊断日志")
            }
        }''',
'''        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    memoryWatchEnabled.toggle()
                    if memoryWatchEnabled {
                        viewModel.fetchMemoryAsync()
                    }
                } label: {
                    Image(systemName: memoryWatchEnabled ? "gauge.with.needle" : "gauge")
                        .foregroundColor(memoryWatchEnabled ? .blue : .secondary)
                }
                .accessibilityLabel(memoryWatchEnabled ? "关闭内存监控" : "开启内存监控")
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showLogViewer = true
                } label: {
                    Image(systemName: "doc.text.magnifyingglass")
                }
                .accessibilityLabel("查看诊断日志")
            }
        }''')

# fetchMemoryAsync 从 private 改 internal（View 里调用）
patch(p,
'''    /// v0.3.38：内存查询完全异步——独立 Task，绝不阻塞进程列表
    private func fetchMemoryAsync() {''',
'''    /// v0.3.38：内存查询完全异步——独立 Task，绝不阻塞进程列表
    func fetchMemoryAsync() {''')

print('② 监控开关补丁完成')

# ③ 日志导出空白修复：sysmon.log → 复制为 sysmon.txt 再分享（QuickLook 不认 .log）
p3 = 'EscapeOS/Views/ProcessManagerView.swift'
patch(p3,
'''            .sheet(isPresented: $showShare) {
                if let url = shareURL {
                    ActivityShareView(url: url)
                }
            }
            .overlay {
                if copied {
                    Text("已复制")
                        .font(.caption)
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(.black.opacity(0.7)))
                        .transition(.opacity)
                }
            }''',
'''            .sheet(isPresented: $showShare) {
                if let url = shareURL {
                    ActivityShareView(url: url)
                }
            }
            .overlay {
                if copied {
                    Text("已复制")
                        .font(.caption)
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(.black.opacity(0.7)))
                        .transition(.opacity)
                }
            }
            .onAppear { prepareShareCopy() }''')

# SysmonLogView 的导出按钮改为复制到 .txt 再分享
patch(p3,
'''            .safeAreaInset(edge: .bottom) {
                Button {
                    shareURL = SysmonLogger.shared.logFileURL
                    showShare = true
                } label: {
                    Label("导出分享日志", systemImage: "square.and.arrow.up")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .padding()
                .disabled(SysmonLogger.shared.fullLog().isEmpty)
            }''',
'''            .safeAreaInset(edge: .bottom) {
                Button {
                    shareURL = makeShareCopy()
                    showShare = true
                } label: {
                    Label("导出分享日志", systemImage: "square.and.arrow.up")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .padding()
                .disabled(SysmonLogger.shared.fullLog().isEmpty)
            }''')

# 加 makeShareCopy 函数（复制 .log → .txt，QuickLook 可预览）
s = io.open(p3, encoding='utf-8').read()
s += '''

extension SysmonLogView {
    /// .log 文件 QuickLook 无法预览（空白）→ 复制为 .txt 再分享
    private func makeShareCopy() -> URL? {
        let src = SysmonLogger.shared.logFileURL
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("escapeos-sysmon-\\(Int(Date().timeIntervalSince1970)).txt")
        try? FileManager.default.removeItem(at: tmp)
        guard (try? FileManager.default.copyItem(at: src, to: tmp)) != nil else { return src }
        return tmp
    }
}
'''
io.open(p3, 'w', encoding='utf-8', newline='\n').write(s)

print('③ 导出 .txt 修复完成')
