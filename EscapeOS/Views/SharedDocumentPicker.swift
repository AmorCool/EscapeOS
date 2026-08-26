import SwiftUI
import UniformTypeIdentifiers
import UIKit

/// Unified document picker used across EscapeOS.
///
/// SwiftUI's `.fileImporter` returns a security-scoped URL that the LiveContainer
/// guest sandbox often refuses to access (`startAccessingSecurityScopedResource()`
/// fails unless the host's "fix file picker" hook is enabled). This single call
/// point uses `UIDocumentPickerViewController` with `asCopy: true`, which copies
/// the selected file into the app sandbox before handing it back, so the read
/// works regardless of the LC file-picker patches.
///
/// Every file-import in the app should route through here — there is exactly one
/// code path, so the LiveContainer import bug is fixed in one place.
enum SharedDocumentPicker {

    /// Present a document picker and return URLs that already live inside the app
    /// sandbox (the system copied them), so no security-scoped access dance is needed.
    static func present(
        allowedTypes: [UTType],
        allowsMultipleSelection: Bool = false,
        asCopy: Bool = true,
        onPicked: @escaping ([URL]) -> Void,
        onCancelled: (() -> Void)? = nil
    ) {
        let controller = UIDocumentPickerViewController(forOpeningContentTypes: allowedTypes, asCopy: asCopy)
        controller.allowsMultipleSelection = allowsMultipleSelection

        let delegate = SharedDocumentPickerDelegate(onPicked: onPicked, onCancelled: onCancelled)
        SharedDocumentPickerDelegateStore.shared.retain(delegate)
        controller.delegate = delegate

        present(controller)
    }

    private static func present(_ controller: UIViewController) {
        guard let scene = UIApplication.shared.connectedScenes
            .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene
            ?? UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let root = scene.windows.first?.rootViewController else { return }
        topViewController(from: root)?.present(controller, animated: true)
    }

    private static func topViewController(from controller: UIViewController?) -> UIViewController? {
        guard let controller = controller else { return nil }
        if let presented = controller.presentedViewController {
            return topViewController(from: presented)
        }
        return controller
    }
}

final class SharedDocumentPickerDelegate: NSObject, UIDocumentPickerDelegate {
    let onPicked: ([URL]) -> Void
    let onCancelled: (() -> Void)?

    init(onPicked: @escaping ([URL]) -> Void, onCancelled: (() -> Void)?) {
        self.onPicked = onPicked
        self.onCancelled = onCancelled
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        onPicked(urls)
        SharedDocumentPickerDelegateStore.shared.release(self)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        onCancelled?()
        SharedDocumentPickerDelegateStore.shared.release(self)
    }
}

/// Retains picker delegates for the lifetime of the presentation so ARC does not
/// release them before the delegate callback fires.
final class SharedDocumentPickerDelegateStore {
    static let shared = SharedDocumentPickerDelegateStore()
    private var delegates: [SharedDocumentPickerDelegate] = []
    private let lock = NSLock()

    func retain(_ delegate: SharedDocumentPickerDelegate) {
        lock.lock(); defer { lock.unlock() }
        delegates.append(delegate)
    }

    func release(_ delegate: SharedDocumentPickerDelegate) {
        lock.lock(); defer { lock.unlock() }
        delegates.removeAll { $0 === delegate }
    }
}

extension View {
    /// Drop-in replacement for `.fileImporter` that works inside LiveContainer.
    /// `onPicked` receives URLs already copied into the app sandbox.
    func documentPicker(
        isPresented: Binding<Bool>,
        allowedTypes: [UTType],
        allowsMultipleSelection: Bool = false,
        onPicked: @escaping ([URL]) -> Void
    ) -> some View {
        self.modifier(SharedDocumentPickerModifier(
            isPresented: isPresented,
            allowedTypes: allowedTypes,
            allowsMultipleSelection: allowsMultipleSelection,
            onPicked: onPicked
        ))
    }
}

struct SharedDocumentPickerModifier: ViewModifier {
    @Binding var isPresented: Bool
    let allowedTypes: [UTType]
    let allowsMultipleSelection: Bool
    let onPicked: ([URL]) -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: isPresented) { presented in
                if presented {
                    SharedDocumentPicker.present(
                        allowedTypes: allowedTypes,
                        allowsMultipleSelection: allowsMultipleSelection
                    ) { urls in
                        onPicked(urls)
                        isPresented = false
                    } onCancelled: {
                        isPresented = false
                    }
                }
            }
    }
}
