import SwiftUI
import UniformTypeIdentifiers

/// Thin wrapper around the shared document picker for pairing files.
///
/// The actual mechanism lives in `SharedDocumentPicker` so every file import in
/// the app routes through one code path (and the LiveContainer import bug is fixed
/// in exactly one place). This keeps the previous `pairingFilePicker(...)` API.
struct PairingFilePickerModifier: ViewModifier {
    @Binding var isPresented: Bool
    let onPicked: (Result<Data, Error>) -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: isPresented) { presented in
                if presented {
                    let types: [UTType] = [
                        .item,
                        .data,
                        .content,
                        .propertyList,
                        .xml,
                        .text,
                        UTType(filenameExtension: "mobiledevicepairing", conformingTo: .data) ?? .data
                    ]
                    SharedDocumentPicker.present(allowedTypes: types, allowsMultipleSelection: false) { urls in
                        if let url = urls.first {
                            do {
                                onPicked(.success(try Data(contentsOf: url)))
                            } catch {
                                onPicked(.failure(error))
                            }
                        } else {
                            onPicked(.failure(NSError(
                                domain: "EscapeOS",
                                code: -3,
                                userInfo: [NSLocalizedDescriptionKey: "未选择配对文件."]
                            )))
                        }
                        isPresented = false
                    } onCancelled: {
                        isPresented = false
                    }
                }
            }
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
