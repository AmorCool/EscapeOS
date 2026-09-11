import SwiftUI

/// v0.3.297：AppStore 商店 —— 首次使用声明
///
/// 本模块仅用于技术学习、研究与自用测试：分析第三方客户端的公开通信机制，
/// 实现同构的系统级分发通道（itms-services）与分发包解析。不提供任何分发内容，
/// 也不内置任何第三方分发地址；使用者需自行承担相应责任。
enum AppStoreDisclaimer {
    private static let key = "AppStoreDisclaimerAccepted_v1"

    static var accepted: Bool {
        UserDefaults.standard.bool(forKey: key)
    }

    static func accept() {
        UserDefaults.standard.set(true, forKey: key)
    }

    static func reset() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

struct AppStoreDisclaimerView: View {
    var onAccept: () -> Void
    var onDecline: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.shield.fill")
                        .foregroundStyle(.orange)
                    Text("使用前须知")
                        .font(.headline)
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        bullet("本功能仅用于技术学习、研究与自用测试，用于分析公开的通信协议与系统分发机制。")
                        bullet("请勿用于任何商业用途、二次分发、破解传播或其他违法违规用途。")
                        bullet("请勿用于黑灰产：不得传播、售卖、代装任何未获授权的应用。")
                        bullet("使用所产生的全部后果由使用者自行承担；请于 24 小时内自行删除相关内容。")
                        bullet("本 App 不提供任何分发包内容，也不内置任何第三方分发地址。")
                        bullet("如相关服务方调整接口或策略，本功能可能随时失效。")
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
                .frame(maxHeight: 280)

                HStack(spacing: 10) {
                    Button {
                        onDecline()
                    } label: {
                        Text("不同意")
                            .font(.body.weight(.medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                            .background(Color(.tertiarySystemFill), in: Capsule())
                            .foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)

                    Button {
                        onAccept()
                    } label: {
                        Text("我已阅读并同意")
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                            .background(Color.blue, in: Capsule())
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(18)
            .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(.horizontal, 22)
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Text("•").foregroundStyle(.secondary)
            Text(text)
        }
    }
}
