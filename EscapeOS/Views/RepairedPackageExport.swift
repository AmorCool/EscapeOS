import SwiftUI

// 共享转换 · 「导出修补产物」入口（用户需求：把修补后的包导出来）
//
// 目标始终是 `RepairResult.repairedIPAPath` —— 即**修补产物**，绝不导出原件：
//   · 新落点：`Imports/<包名>/repaired.ipa`
//   · 老平铺：`Imports/repaired.ipa`（`RepairService.repairedOutputPath` 与原件同目录、不同名）
// 明文包无需修补，其产物即原件，页脚据实说明。
//
// 三种可导出状态，一律「先给结论，不让用户点了才报错」：
//   · 尚未修补 / 修补失败 ⇒ 入口**禁用**，页脚写清原因；
//   · 已修补（含「修补后取消安装」，此时产物已落盘）⇒ 可导出；
//   · 产物文件已被清理 ⇒ 禁用并提示重新修补。
//
// 独立成文件：导出是**纯附加**能力，与导入 / 修补主流程解耦，
// 并行改动 ImportView 时只需保留一行挂载，互不覆盖。

struct RepairedPackageExportSection: View {

    /// 修补结果（`nil` = 尚未修补）。
    let repairResult: RepairResult?
    /// 当前包（用于区分「明文包无需修补」的文案；`nil` 时按加密包措辞）。
    let record: ImportRecord?

    /// 系统分享面板目标（`ShareSheet`，仓库既有做法）。
    @State private var shareTarget: ShareTarget?

    var body: some View {
        Section {
            Button {
                export()
            } label: {
                Label("导出修补后的安装包", systemImage: "square.and.arrow.up")
            }
            .disabled(exportURL == nil)
        } header: {
            Text("导出")
        } footer: {
            Text(footerText)
        }
        .sheet(item: $shareTarget) { target in
            ShareSheet(items: [target.url])
        }
    }

    /// 可导出的修补产物 URL：产物路径已生成、且文件仍在磁盘上。
    private var exportURL: URL? {
        guard let path = repairResult?.repairedIPAPath else { return nil }
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// 页脚：说明**导出的是哪个包**，以及不可导出时的原因。
    private var footerText: String {
        guard let r = repairResult else {
            return "尚未修补. 先完成修补后，这里可以导出修补后的安装包."
        }
        switch r.status {
        case .failed, .needsUserChoice:
            return "修补未完成，没有可导出的安装包. 请先解决上方问题后重新修补."
        case .ok, .skipped:
            guard let path = r.repairedIPAPath else {
                return "修补未完成，没有可导出的安装包. 请先完成修补."
            }
            guard FileManager.default.fileExists(atPath: path) else {
                return "修补产物已不存在（可能已被清理）. 请重新修补后再导出."
            }
            if record?.payload.encrypted == false {
                return "导出的是这次导入的安装包（明文包，无需修补）."
            }
            return "导出的是修补后的安装包 repaired.ipa，不是原始包."
        }
    }

    private func export() {
        guard let url = exportURL else {
            // 正常路径下按钮已禁用、到不了这里；留一句可读兜底，避免静默无反应。
            ToastCenter.shared.show("没有可导出的安装包")
            return
        }
        shareTarget = ShareTarget(url: url)
    }
}
