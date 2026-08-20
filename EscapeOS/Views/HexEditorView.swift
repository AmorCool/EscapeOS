import SwiftUI

/// Filza-style hex dump with optional in-place byte editing for files under 512 KB.
struct HexEditorView: View {
    @ObservedObject var vm: FileViewerViewModel
    @State private var editOffset: Int?
    @State private var editValue = ""

    private let columns = 8

    var body: some View {
        VStack(spacing: 0) {
            if vm.truncated {
                Text("仅显示前 512 KB 的十六进制预览。超过此大小的文件不可保存。")
                    .font(.caption)
                    .foregroundColor(.orange)
                    .padding(8)
                    .frame(maxWidth: .infinity)
                    .background(Color.orange.opacity(0.12))
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(stride(from: 0, to: vm.bytes.count, by: columns)), id: \.self) { start in
                        HexRow(
                            offset: start,
                            bytes: Array(vm.bytes[start..<min(start + columns, vm.bytes.count)]),
                            columns: columns
                        ) { tapped in
                            guard !vm.truncated else { return }
                            editOffset = tapped
                            if tapped < vm.bytes.count {
                                editValue = String(format: "%02X", vm.bytes[tapped])
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 12)
            }
        }
        .background(Color(UIColor.systemBackground))
        .alert("编辑字节", isPresented: Binding(
            get: { editOffset != nil },
            set: { if !$0 { editOffset = nil } }
        )) {
            TextField("00–FF", text: $editValue)
                .autocapitalization(.allCharacters)
                .disableAutocorrection(true)
            Button("取消", role: .cancel) { editOffset = nil }
            Button("设置") { applyEdit() }
        } message: {
            if let offset = editOffset {
                Text("偏移 \(String(format: "0x%08X", offset))")
            }
        }
    }

    private func applyEdit() {
        guard let offset = editOffset, offset < vm.bytes.count else { return }
        let cleaned = editValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = UInt8(cleaned, radix: 16) else { return }
        vm.bytes[offset] = value
        vm.markDirty()
        editOffset = nil
    }
}

private struct HexRow: View {
    let offset: Int
    let bytes: [UInt8]
    let columns: Int
    let onTap: (Int) -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(String(format: "%08X", offset))
                .foregroundColor(.secondary)
                .frame(width: 74, alignment: .leading)
            HStack(spacing: 4) {
                ForEach(0..<columns, id: \.self) { index in
                    if index < bytes.count {
                        Button {
                            onTap(offset + index)
                        } label: {
                            Text(String(format: "%02X", bytes[index]))
                                .foregroundColor(.primary)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Text("  ")
                    }
                }
            }
            Text(ascii)
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        .font(.system(size: 12, design: .monospaced))
    }

    private var ascii: String {
        String(bytes.map { byte in
            (byte >= 32 && byte < 127) ? Character(UnicodeScalar(byte)) : "."
        })
    }
}
