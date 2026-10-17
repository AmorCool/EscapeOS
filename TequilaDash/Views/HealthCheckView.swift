import SwiftUI

/// v0.3.200：设备体检页 —— 执行 SecurityScanner 真实检测.
/// 得分通过 binding 回传主页灵动球（立即体检后主页分数同步刷新）.
struct HealthCheckView: View {
    /// 体检得分绑定（主页灵动球显示用）
    var score: Binding<Int>? = nil
    @State private var phase: Phase = .idle
    @State private var results: [SecurityCheckResult] = []
    @State private var currentCheckIndex = 0
    @State private var finalScore = 0

    enum Phase { case idle, scanning, done }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                switch phase {
                case .idle, .scanning:
                    scanProgressCard
                case .done:
                    scoreCard
                    resultsCard
                    // 淡蓝底（`TintedButtonStyle`），**不用纯蓝实底**；圆角对齐 TRApp 大按钮（12）
                    Button {
                        AppHaptics.tap()
                        startScan()
                    } label: {
                        Label("重新体检", systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(TintedButtonStyle(tint: AppTheme.accent, radius: AppRadius.button))
                }
            }
            .padding(.horizontal, AppTheme.pageInset)
            .padding(.top, 4)
            .padding(.bottom, 32)
        }
        .scrollContentBackground(.hidden)
        .background(Color(.systemBackground))
        .navigationTitle("设备体检")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if phase == .idle { startScan() }
        }
    }

    // MARK: 扫描进度卡（灵动环 + 当前项）
    private var scanProgressCard: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .stroke(Color(.systemGray5), lineWidth: 8)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(AppTheme.accent, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.25), value: progress)
                VStack(spacing: 2) {
                    Text("\(Int(progress * 100))%")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .contentTransition(.numericText())
                    Text(phase == .scanning ? currentCheckName : "准备体检…")
                        .font(AppFont.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 160, height: 160)
            Text("正在扫描 \(currentCheckIndex)/\(SecurityScanner.checkIDs.count)")
                .font(AppFont.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .background(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
            .fill(Color(uiColor: .secondarySystemGroupedBackground)))
    }

    private var progress: CGFloat {
        guard phase == .scanning else { return 0 }
        return CGFloat(currentCheckIndex) / CGFloat(max(SecurityScanner.checkIDs.count, 1))
    }
    private var currentCheckName: String {
        let names: [String: String] = [
            "urlscheme": "越狱商店 Scheme", "files": "可疑文件路径",
            "writable": "系统目录", "dyld": "注入库",
            "objc": "运行时类", "interpreters": "解释器",
            "symlink": "符号链接", "fork": "进程权限",
            "executables": "可疑可执行", "ports": "可疑端口",
            "env": "环境变量", "libraryNames": "逆向库",
            "mainExe": "主可执行文件", "taskPorts": "进程任务端口",
            "provisioning": "权限配置文件", "entitlements": "关键权限",
        ]
        let id = currentCheckIndex < SecurityScanner.checkIDs.count
            ? SecurityScanner.checkIDs[currentCheckIndex] : ""
        return names[id] ?? "…"
    }

    // MARK: 结果
    private var scoreCard: some View {
        VStack(spacing: 6) {
            Text("\(finalScore)")
                .font(.system(size: 64, weight: .bold, design: .rounded))
                .contentTransition(.numericText())
                .foregroundStyle(scoreColor)
            Text(scoreLabel)
                .font(AppFont.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .background(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
            .fill(Color(uiColor: .secondarySystemGroupedBackground)))
    }

    private var resultsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("检测明细")
                .font(AppFont.headline)
                .padding(.bottom, 6)
            ForEach(results) { item in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: item.iconName)
                        .foregroundStyle(item.color)
                        .frame(width: 24)
                        .appSymbol()
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(AppFont.subheadlineEmphasis)
                        Text(item.detail)
                            .font(AppFont.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 8)
                AppHairline().opacity(item.id == results.last?.id ? 0 : 1)
            }
        }
        .padding(AppMetrics.cardPadding)
        .background(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
            .fill(Color(uiColor: .secondarySystemGroupedBackground)))
    }

    // v0.3.626：改走统一 token（阈值 90/70 与原实现一致，但取色改为明暗自适应）。
    // 原实现用系统 .blue/.yellow/.orange（单值色，深色模式下对比度不足，违反规则 6）。
    private var scoreColor: Color { AppTheme.scoreColor(finalScore) }
    private var scoreLabel: String {
        switch finalScore {
        case 90...: return "设备很安全"
        case 70..<90: return "安全状况良好"
        default: return "发现风险项"
        }
    }

    // MARK: 扫描执行（逐项动画推进）
    private func startScan() {
        phase = .scanning
        currentCheckIndex = 0
        results = []
        let ids = SecurityScanner.checkIDs
        // 用串行 async 逐项执行，UI 显示推进
        Task {
            for (i, id) in ids.enumerated() {
                try? await Task.sleep(nanoseconds: 300_000_000)  // 每项节奏
                let result: SecurityCheckResult
                switch id {
                case "urlscheme": result = SecurityScanner.checkURLSchemes()
                case "files": result = SecurityScanner.checkSuspiciousFiles()
                case "writable": result = SecurityScanner.checkSystemDirsWritable()
                case "dyld": result = SecurityScanner.checkDYLDInjection()
                case "objc": result = SecurityScanner.checkSuspiciousObjCClasses()
                case "interpreters": result = SecurityScanner.checkAccessibleInterpreters()
                case "symlink": result = SecurityScanner.checkSuspiciousSymbolicLinks()
                case "fork": result = SecurityScanner.checkFork()
                case "executables": result = SecurityScanner.checkSuspiciousExecutables()
                case "ports": result = SecurityScanner.checkSuspiciousPorts()
                case "env": result = SecurityScanner.checkEnvironmentVariables()
                case "libraryNames": result = SecurityScanner.checkSuspiciousLibraryNames()
                case "mainExe": result = SecurityScanner.checkMainExecutableIntegrity()
                case "taskPorts": result = SecurityScanner.checkExceptionPorts()
                case "provisioning": result = SecurityScanner.checkProvisioningProfiles()
                case "entitlements": result = SecurityScanner.checkEntitlements()
                default: continue
                }
                await MainActor.run {
                    currentCheckIndex = i + 1
                    results.append(result)
                }
            }
            await MainActor.run {
                finalScore = max(0, 100 - results.reduce(0) { $0 + $1.penalty })
                phase = .done
                score?.wrappedValue = finalScore
            }
        }
    }
}