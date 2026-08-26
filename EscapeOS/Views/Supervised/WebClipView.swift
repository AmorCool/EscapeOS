import SwiftUI
import PhotosUI
import UIKit

// MARK: - 网页快捷方式（移植自 Lithium WebclipView）

struct WebClipView: View {
    @State private var label = ""
    @State private var url = ""
    @State private var fullScreen = true
    @State private var precomposed = false
    @State private var iconData = Data()

    @State private var selectedPhoto: PhotosPickerItem?
    @State private var showPhotosPicker = false

    @State private var shareTarget: ShareTarget?
    @State private var safariTarget: SafariTarget?
    @State private var errorMessage = ""
    @State private var showError = false

    var body: some View {
        List {
            Section {
                VStack(alignment: .center, spacing: 8) {
                    Menu {
                        Button {
                            showPhotosPicker = true
                        } label: {
                            Label("从相册选择", systemImage: "photo")
                        }
                    } label: {
                        if let ui = UIImage(data: iconData) {
                            Image(uiImage: ui)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 72, height: 72)
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                        } else {
                            RoundedRectangle(cornerRadius: 16)
                                .fill(Color(.secondarySystemGroupedBackground))
                                .frame(width: 72, height: 72)
                                .overlay {
                                    Image(systemName: "plus")
                                        .font(.title2)
                                        .foregroundStyle(.secondary)
                                }
                        }
                    }

                    TextField("标题", text: $label)
                        .multilineTextAlignment(.center)
                        .font(.system(size: 13, weight: .medium))
                        .frame(maxWidth: 160)
                }
                .frame(maxWidth: .infinity, alignment: .center)
            } header: {
                Label("外观", systemImage: "paintbrush")
            }

            Section {
                TextField("网页地址（含 https://）", text: $url)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Toggle("全屏打开", isOn: $fullScreen)
                Toggle("使用预合成图标", isOn: $precomposed)
            } header: {
                Label("属性", systemImage: "switch.2")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("网页快捷方式")
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .supervisedInstallFooter(title: "生成并安装") {
            buildAndInstall()
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
                        clearFields()
                    } label: {
                        Label("清空", systemImage: "xmark")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
            }
        }
        .photosPicker(isPresented: $showPhotosPicker, selection: $selectedPhoto, matching: .images)
        .onChange(of: selectedPhoto) { received in
            guard let received else { return }
            Task {
                if let data = try? await received.loadTransferable(type: Data.self) {
                    iconData = cropImage(data)
                }
            }
        }
        .sheet(item: $shareTarget) { target in
            ShareSheet(items: [target.url])
        }
        .sheet(item: $safariTarget, onDismiss: { ProfileHTTPServer.shared.stop() }) { target in
            SafariSheet(url: target.url)
        }
        .alert("操作失败", isPresented: $showError) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
        .onAppear(perform: reload)
    }

    // MARK: - 操作

    private func reload() {
        do {
            let dict = try SupervisedProfileStore.load(.webclip)
            guard let pl = (dict["PayloadContent"] as? NSArray)?.firstObject as? NSDictionary else { return }
            label = pl["Label"] as? String ?? ""
            url = pl["URL"] as? String ?? ""
            fullScreen = pl["FullScreen"] as? Bool ?? true
            precomposed = pl["Precomposed"] as? Bool ?? false
            iconData = pl["Icon"] as? Data ?? Data()
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    private func buildAndInstall() {
        guard !label.trimmingCharacters(in: .whitespaces).isEmpty,
              !url.trimmingCharacters(in: .whitespaces).isEmpty else {
            errorMessage = "请先填写标题与网页地址。"
            showError = true
            return
        }
        do {
            let dict = try SupervisedProfileStore.load(.webclip)
            dict["PayloadDisplayName"] = "网页快捷方式：\(label)"
            guard let pl = (dict["PayloadContent"] as? NSArray)?.firstObject as? NSMutableDictionary else {
                throw SupervisedProfileStore.StoreError.corruptProfile("esc.webclip")
            }
            pl["Label"] = label
            pl["URL"] = url
            pl["Icon"] = iconData
            pl["FullScreen"] = fullScreen
            pl["Precomposed"] = precomposed
            try SupervisedProfileStore.save(.webclip, dict: dict)
            safariTarget = SafariTarget(url: try SupervisedProfileStore.installURL(.webclip))
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    private func clearFields() {
        label = ""
        url = ""
        fullScreen = true
        precomposed = false
        iconData = Data()
        selectedPhoto = nil
    }

    private func exportProfile() {
        // 先把当前字段写回，再导出
        do {
            let dict = try SupervisedProfileStore.load(.webclip)
            guard let pl = (dict["PayloadContent"] as? NSArray)?.firstObject as? NSMutableDictionary else {
                throw SupervisedProfileStore.StoreError.corruptProfile("esc.webclip")
            }
            pl["Label"] = label
            pl["URL"] = url
            pl["Icon"] = iconData
            pl["FullScreen"] = fullScreen
            pl["Precomposed"] = precomposed
            try SupervisedProfileStore.save(.webclip, dict: dict)
            let url = try SupervisedProfileStore.exportURL(.webclip)
            shareTarget = ShareTarget(url: url)
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    /// 将图标裁剪为 256×256 居中正方形（与 Lithium 一致）。
    private func cropImage(_ data: Data) -> Data {
        guard let image = UIImage(data: data) else { return data }
        let target = CGSize(width: 256, height: 256)
        let wScale = target.width / image.size.width
        let hScale = target.height / image.size.height
        let scale = max(wScale, hScale)
        let scaled = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let x = (target.width - scaled.width) / 2
        let y = (target.height - scaled.height) / 2
        let render = UIGraphicsImageRenderer(size: target)
        let cropped = render.image { _ in
            image.draw(in: CGRect(origin: CGPoint(x: x, y: y), size: scaled))
        }
        return cropped.pngData() ?? data
    }
}
