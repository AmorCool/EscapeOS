import SwiftUI

/// Entry point for the "增加内存限制" feature ported from GetMoreRam.
/// The Apple ID account and Anisette server are managed centrally in
/// Settings > Apple ID 账户 / Anisette 服务器; this view only consumes them.
struct IncreaseMemoryView: View {
    @StateObject private var settings = MemoryLimitSettings.shared
    @State private var showNotReadyAlert = false

    var body: some View {
        List {
            accountSection
            anisetteSection
            actionSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("增加内存限制")
        .navigationBarTitleDisplayMode(.inline)
        .alert("功能未就绪", isPresented: $showNotReadyAlert) {
            Button("好", role: .cancel) {}
        } message: {
            Text("Apple Developer API 调用尚未接入。请先在此配置账户与服务器，后续版本将完成开启逻辑。")
        }
    }

    private var accountSection: some View {
        Section(header: Text("Apple ID 账户")) {
            if settings.isLoggedIn {
                HStack {
                    Text("账号")
                    Spacer()
                    Text(settings.appleID)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            } else {
                HStack {
                    Text("状态")
                    Spacer()
                    Text("未登录")
                        .foregroundColor(.secondary)
                }
                Text("请在「更多 → 设置 → Apple ID 账户」中登录。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var anisetteSection: some View {
        Section(header: Text("Anisette 服务器")) {
            HStack {
                Text("当前服务器")
                Spacer()
                Text(MemoryLimitSettings.host(from: settings.anisetteServer))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Text("在「更多 → 设置」里可以切换 SideStore / StikStore 等备用服务器。")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var actionSection: some View {
        Section(header: Text("操作"), footer: Text("开启后需要重新安装对应 App 才能使 INCREASED_MEMORY_LIMIT 能力生效。")) {
            Button {
                showNotReadyAlert = true
            } label: {
                HStack {
                    Image(systemName: "memorychip")
                    Text("开启增加内存限制")
                }
            }
            .disabled(!settings.isLoggedIn)
        }
    }
}
