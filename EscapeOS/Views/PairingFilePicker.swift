import SwiftUI
import UniformTypeIdentifiers
import UIKit

/// A LiveContainer-style document picker for pairing files.
///
/// SwiftUI's `.fileImporter` returns a security-scoped URL that the LiveContainer
/// sandbox often refuses to access unless the host's "fix file picker" hook is
/// enabled. This wrapper uses `UIDocumentPickerViewController` with `asCopy: true`,
/// which copies the selected file into the app sandbox before handing it back,
/// so the read works regardless of LC's file-picker patches.
struct PairingFilePickerModifier: ViewModifier {
    @Binding var isPresented: Bool
    let onPicked: (Result<Data, Error>) -> Void

    @State private var picker: UIDocumentPickerViewController?
    @State private var delegate: PairingFilePickerDelegate?

    func body(content: Content) -> some View {
        content
            .onChange(of: isPresented) { presented in
                if presented, picker == nil {
                    let types: [UTType] = [
                        .item,
                        .data,
                        .content,
                        .propertyList,
                        .xml,
                        .text,
                        UTType(filenameExtension: "mobiledevicepairing", conformingTo: .data) ?? .data
                    ]
                    let controller = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
                    controller.allowsMultipleSelection = false

                    let delegate = PairingFilePickerDelegate { result in
                        onPicked(result)
                        self.isPresented = false
                        self.picker = nil
                        self.delegate = nil
                    }
                    controller.delegate = delegate
                    self.delegate = delegate
                    self.picker = controller
                    present(controller)
                } else if !presented, let picker = picker {
                    picker.dismiss(animated: true)
                    self.picker = nil
                    self.delegate = nil
                }
            }
    }

    private func present(_ controller: UIViewController) {
        let scene = UIApplication.shared.connectedScenes
            .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene
            ?? UIApplication.shared.connectedScenes.first as? UIWindowScene
        guard let root = scene?.windows.first?.rootViewController else { return }
        topViewController(from: root)?.present(controller, animated: true)
    }

    private func topViewController(from controller: UIViewController?) -> UIViewController? {
        guard let controller = controller else { return nil }
        if let presented = controller.presentedViewController {
            return topViewController(from: presented)
        }
        return controller
    }
}

final class PairingFilePickerDelegate: NSObject, UIDocumentPickerDelegate {
    let onPicked: (Result<Data, Error>) -> Void

    init(onPicked: @escaping (Result<Data, Error>) -> Void) {
        self.onPicked = onPicked
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else {
            onPicked(.failure(NSError(
                domain: "EscapeOS",
                code: -3,
                userInfo: [NSLocalizedDescriptionKey: "未选择配对文件。"]
            )))
            return
        }
        do {
            let data = try Data(contentsOf: url)
            onPicked(.success(data))
        } catch {
            onPicked(.failure(error))
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        onPicked(.failure(NSError(
            domain: "EscapeOS",
            code: -4,
            userInfo: [NSLocalizedDescriptionKey: "已取消选择。"]
        )))
    }
}

extension View {
    func pairingFilePicker(
        isPresented: Binding<Bool>,
        onPicked: @escaping (Result<Data, Error>) -> Void
    ) -> some View {
        self.modifier(PairingFilePickerModifier(isPresented: isPresented, onPicked: onPicked))
    }
}
