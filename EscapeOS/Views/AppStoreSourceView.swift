import SwiftUI

/// v0.3.297：AppStore 商店 —— 分发源管理
///
/// 源 = 「给一个 App，返回它的 manifest plist 地址」的服务。
/// 安装时 App 只用系统 itms-services 把 plist 交给 iOS，由系统下载安装
/// （爱思助手手机端同一条通道）。
struct AppStoreSourceView: View {
    @State private var sources: [AppStoreSource] = []
    @State private var editing: AppStoreSource?
    @State private var showEditor = false

    var body: some View {
        List {
            Section {
                if sources.isEmpty {
                    Text("还没有分发源")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(sources) { s in
                        Button {
                            editing = s
                            showEditor = true
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Text(s.name).font(.body)
                                    if s.enabled {
                                        Text("启用").font(.caption2)
                                            .padding(.horizontal, 6).padding(.vertical, 1)
                                            .background(Color.green.opacity(0.15), in: Capsule())
                                            .foregroundStyle(.green)
                                    } else {
                                        Text("停用").font(.caption2)
                                            .padding(.horizontal, 6).padding(.vertical, 1)
                                            .background(Color.gray.opacity(0.15), in: Capsule())
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                if !s.plistURLTemplate.isEmpty {
                                    Text("plist 模板：\(s.plistURLTemplate)")
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                } else if !s.infoURLTemplate.isEmpty {
                                    Text("接口：\(s.infoURLTemplate)")
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                } else {
                                    Text("未配置地址").font(.caption2).foregroundStyle(.orange)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete { idx in
                        for i in idx { AppStoreSourceStore.shared.remove(id: sources[i].id) }
                        reload()
                    }
                }
            } header: {
                Text("分发源")
            } footer: {
                Text("安装时按顺序尝试已启用的源：先用 plist 模板直出地址；没有模板则请求接口，按字段路径从返回 JSON 取 plist 地址。地址里可用占位符 {id}、{bundleId}、{name}、{version}。")
                    .font(.caption2)
            }
        }
        .navigationTitle("分发源管理")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    editing = AppStoreSource(name: "")
                    showEditor = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showEditor) {
            if let editing {
                AppStoreSourceEditor(source: editing) { saved in
                    if sources.contains(where: { $0.id == saved.id }) {
                        AppStoreSourceStore.shared.update(saved)
                    } else {
                        AppStoreSourceStore.shared.add(saved)
                    }
                    reload()
                }
            }
        }
        .onAppear { reload() }
    }

    private func reload() {
        sources = AppStoreSourceStore.shared.sources
    }
}

/// 源编辑页
struct AppStoreSourceEditor: View {
    @State var source: AppStoreSource
    var onSave: (AppStoreSource) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("基本信息") {
                    TextField("源名称", text: $source.name)
                    Toggle("启用", isOn: $source.enabled)
                }
                Section {
                    TextField("https://example.com/appinfo.xhtml?appid={id}", text: $source.infoURLTemplate, axis: .vertical)
                        .font(.footnote.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("plist_s", text: $source.plistFieldPath)
                        .font(.footnote.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("方式一：接口取 plist")
                } footer: {
                    Text("请求上面的接口，按字段路径（支持 a.b.c 嵌套）从返回 JSON 里取 manifest plist 地址。")
                        .font(.caption2)
                }
                Section {
                    TextField("https://example.com/{bundleId}.plist", text: $source.plistURLTemplate, axis: .vertical)
                        .font(.footnote.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("方式二：plist 模板直出")
                } footer: {
                    Text("填写后优先使用它，不再请求接口。")
                        .font(.caption2)
                }
                Section {
                    TextField("{\"X-Token\":\"abc\"}", text: $source.extraHeaders, axis: .vertical)
                        .font(.footnote.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("额外请求头（JSON，可空）")
                }
            }
            .navigationTitle(source.name.isEmpty ? "新增源" : "编辑源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") {
                        onSave(source)
                        dismiss()
                    }
                    .disabled(source.name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}
