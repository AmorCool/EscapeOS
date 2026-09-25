import SwiftUI

/// 反激活设备 —— 移植自爱思 9.0「反激活设备」.
///
/// 版式：**读状态** → 列出三条前置条件 → 全过才允许点「反激活设备」，
/// 点击后弹**不可跳过**的确认（写清「会变成未激活状态」「带激活锁会变砖」）.
/// 视图只做渲染与状态机；判定与下发全在 `ActivationService`.
/// 界面只留必要信息（项目铁律 4）：不放原理解释、不放 footnote 长句.
struct ActivationView: View {

    @State private var status: ActivationService.Status?
    @State private var loading = false
    @State private var deactivating = false
    @State private var errorText: String?
    @State private var resultText: String?
    @State private var confirmDeactivate = false

    private var isBusy: Bool { loading || deactivating }

    var body: some View {
        List {
            preconditionSection
            actionSection
        }
        .navigationTitle("反激活设备")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: refresh)
        .alert("确认反激活设备？", isPresented: $confirmDeactivate) {
            Button("取消", role: .cancel) {}
            Button("反激活", role: .destructive) { performDeactivate() }
        } message: {
            Text("反激活后设备会立即回到激活界面（变成未激活状态），需走 Apple 官方激活才能回到桌面.\n执行前请先关闭设备网络，否则设备会自动重新激活.\n若已开启激活锁（查找我的 iPhone），反激活后将无法重新激活，即变砖.")
        }
    }

    // MARK: - 前置条件

    private var preconditionSection: some View {
        Section {
            HStack {
                Text("设备已激活")
                Spacer()
                Text(status?.activationState.label ?? "读取中")
                    .foregroundStyle(stateColor)
            }
            HStack {
                Text("已关闭「查找我的 iPhone」")
                Spacer()
                Text(status?.activationLock.label ?? "读取中")
                    .foregroundStyle(lockColor)
            }
            HStack {
                Text("已关闭设备网络")
                Spacer()
                Text("需自行确认")
                    .foregroundStyle(.secondary)
            }
            Button {
                refresh()
            } label: {
                HStack {
                    Text("刷新状态")
                    Spacer()
                    if loading { ProgressView() }
                }
            }
            .disabled(isBusy)

            if let errorText {
                Text(errorText)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
            if let resultText {
                Text(resultText)
                    .font(.footnote)
                    .foregroundStyle(.green)
            }
        } header: {
            Text("前置条件")
        }
    }

    // MARK: - 动作

    private var actionSection: some View {
        Section {
            Button(role: .destructive) {
                confirmDeactivate = true
            } label: {
                HStack {
                    Text("反激活设备")
                    Spacer()
                    if deactivating { ProgressView() }
                }
            }
            .disabled(!(status?.canDeactivate ?? false) || isBusy)

            if let reason = status?.blockedReason {
                Text(reason)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
    }

    // MARK: - 颜色

    private var stateColor: Color {
        guard let status else { return .secondary }
        return status.activationState == .activated ? .green : .red
    }

    private var lockColor: Color {
        guard let status else { return .secondary }
        switch status.activationLock {
        case .off: return .green
        case .on, .unknown: return .red
        }
    }

    // MARK: - 动作实现

    private func refresh() {
        guard !isBusy else { return }
        loading = true
        errorText = nil
        resultText = nil
        Task {
            do {
                let read = try await Task.detached(priority: .userInitiated) {
                    try ActivationService.readStatus()
                }.value
                await MainActor.run {
                    status = read
                    loading = false
                }
            } catch {
                await MainActor.run {
                    status = nil
                    loading = false
                    errorText = error.localizedDescription
                }
            }
        }
    }

    private func performDeactivate() {
        guard !isBusy else { return }
        deactivating = true
        errorText = nil
        resultText = nil
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try ActivationService.deactivate()
                }.value
                // 反激活后设备状态会变，重读一次；隧道可能已中断（读不到就置 nil，
                // 按钮随之禁用，避免重复下发）.
                let read = try? await Task.detached(priority: .userInitiated) {
                    try ActivationService.readStatus()
                }.value
                await MainActor.run {
                    deactivating = false
                    status = read
                    resultText = "已下发反激活请求.设备将回到激活界面"
                }
            } catch {
                await MainActor.run {
                    deactivating = false
                    errorText = error.localizedDescription
                }
            }
        }
    }
}
