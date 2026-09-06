import SwiftUI
import UIKit

/// v0.3.217：AFC 文本文件查看/编辑（下载 → TextEditor → 保存上传）.
/// 仅支持小文本（<1MB），二进制/大文件不提供编辑.
struct AfcTextEditorView: View {
    let load: () throws -> Data
    let save: (Data) throws -> Void
    let fileName: String
    let onDone: () -> Void

    @State private var text = ""
    @State private var original = ""
    @State private var loading = true
    @State private var errorText: String?
    @State private var saved = false

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    ProgressView("正在打开…")
                } else if let errorText {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle).foregroundStyle(.orange)
                        Text(errorText).font(.callout).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                } else {
                    TextEditor(text: $text)
                        .font(.system(.footnote, design: .monospaced))
                        .autocorrectionDisabled()
                        .scrollContentBackground(.hidden)
                        .padding(8)
                }
            }
            .navigationTitle(fileName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { onDone() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if loading || errorText != nil {
                        EmptyView()
                    } else {
                        Button("保存") {
                            saveText()
                        }
                        .disabled(text == original || saved)
                    }
                }
            }
        }
        .task {
            do {
                let data = try load()
                original = String(data: data, encoding: .utf8) ?? ""
                text = original
                loading = false
            } catch {
                errorText = error.localizedDescription
                loading = false
            }
        }
    }

    private func saveText() {
        guard let data = text.data(using: .utf8) else {
            errorText = "编码失败"
            return
        }
        do {
            try save(data)
            saved = true
            onDone()
        } catch {
            errorText = error.localizedDescription
        }
    }
}
