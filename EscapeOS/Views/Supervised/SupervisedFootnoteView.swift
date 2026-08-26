import SwiftUI

// MARK: - 锁屏页脚（监管，移植自 Lithium FootnoteView）

/// 通过 `com.apple.shareddeviceconfiguration` 描述文件在锁屏底部添加页脚文字。
/// 与「配置管理」里直接写入 `LockScreenFootnote` 的双轨并存：这里是描述文件路线，
/// 不需要写系统配置目录，只要设备处于监督模式即可。
struct SupervisedFootnoteView: View {
    @State private var leadingText = ""   // IfLostReturnToMessage
    @State private var trailingText = ""  // AssetTagInformation

    @State private var shareTarget: ShareTarget?
    @State private var errorMessage = ""
    @State private var showError = false

    var body: some View {
        List {
            // 锁屏预览（solarium 背景 + 居中文本 + 下划线）
            Section {
                VStack(spacing: 8) {
                    Text((leadingText + trailingText).isEmpty ? "（未设置页脚）" : (leadingText + trailingText))
                        .font(.system(size: 9))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .frame(height: 10)
                    Capsule()
                        .fill(Color.white.opacity(0.6))
                        .frame(width: 145, height: 4)
                        .shadow(color: .black.opacity(0.3), radius: 1, y: 0.5)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 30)
                .listRowInsets(EdgeInsets())
                .listRowBackground(
                    Group {
                        if let img = solariumImage {
                            img.resizable().scaledToFill().offset(y: 10)
                        } else {
                            Color(.systemGroupedBackground)
                        }
                    }
                )
            }

            Section {
                HStack {
                    Text("丢失返还信息")
                    Spacer()
                    TextField("如：拾获请联系 138…", text: $leadingText)
                        .multilineTextAlignment(.trailing)
                }
                HStack {
                    Text("资产标签")
                    Spacer()
                    TextField("如：资产编号 A-123", text: $trailingText)
                        .multilineTextAlignment(.trailing)
                }
            } header: {
                Label("内容", systemImage: "text.line.first.and.arrowtriangle.forward")
            } footer: {
                Text("对应描述文件字段 IfLostReturnToMessage 与 AssetTagInformation，安装后显示在锁屏底部。")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("锁屏页脚")
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .supervisedInstallFooter {
            installProfile()
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button {
                        exportProfile()
                    } label: {
                        Label("导出描述文件", systemImage: "square.and.arrow.up")
                    }
                    Button(role: .destructive) {
                        resetProfile()
                    } label: {
                        Label("重置为默认", systemImage: "gobackward")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
            }
        }
        .sheet(item: $shareTarget) { target in
            ShareSheet(items: [target.url])
        }
        .alert("操作失败", isPresented: $showError) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
        .onAppear(perform: reload)
    }

    private var solariumImage: Image? {
        guard let path = Bundle.main.path(forResource: "solarium", ofType: "jpg"),
              let ui = UIImage(contentsOfFile: path) else { return nil }
        return Image(uiImage: ui)
    }

    private func reload() {
        do {
            let dict = try SupervisedProfileStore.load(.footnote)
            guard let pl = (dict["PayloadContent"] as? NSArray)?.firstObject as? NSDictionary else { return }
            leadingText = pl["IfLostReturnToMessage"] as? String ?? ""
            trailingText = pl["AssetTagInformation"] as? String ?? ""
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    private func installProfile() {
        do {
            let dict = try SupervisedProfileStore.load(.footnote)
            guard let pl = (dict["PayloadContent"] as? NSArray)?.firstObject as? NSMutableDictionary else {
                throw SupervisedProfileStore.StoreError.corruptProfile("esc.footnote")
            }
            pl["IfLostReturnToMessage"] = leadingText
            pl["AssetTagInformation"] = trailingText
            try SupervisedProfileStore.save(.footnote, dict: dict)
            try SupervisedProfileStore.install(.footnote)
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    private func resetProfile() {
        do {
            try SupervisedProfileStore.reset(.footnote)
            leadingText = ""
            trailingText = ""
            try SupervisedProfileStore.load(.footnote) // 重建默认副本
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    private func exportProfile() {
        do {
            let dict = try SupervisedProfileStore.load(.footnote)
            guard let pl = (dict["PayloadContent"] as? NSArray)?.firstObject as? NSMutableDictionary else {
                throw SupervisedProfileStore.StoreError.corruptProfile("esc.footnote")
            }
            pl["IfLostReturnToMessage"] = leadingText
            pl["AssetTagInformation"] = trailingText
            try SupervisedProfileStore.save(.footnote, dict: dict)
            let url = try SupervisedProfileStore.exportURL(.footnote)
            shareTarget = ShareTarget(url: url)
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}
