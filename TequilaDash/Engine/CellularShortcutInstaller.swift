import Foundation
import Network

/// Legacy import entry point. URL acceptance is not proof of a shortcut import.
/// The unsigned, airplane-mode shortcut generator is intentionally not used.
enum CellularShortcutInstaller {
    @MainActor
    @discardableResult
    static func ensureInstalled() async -> Bool {
        UserDefaults.standard.removeObject(forKey: "TequilaDash.CellularShortcutsImported")
        LoginLogger.shared.log("[Cellular] 已停止未验证的快捷指令导入，不切换飞行模式、不拉起快捷指令 App.", category: .general)
        return false
    }

    static func resetImportedFlag() {
        UserDefaults.standard.removeObject(forKey: "TequilaDash.CellularShortcutsImported")
    }
}

/// Loopback-only file server retained for local diagnostics. Readiness and
/// requests share one serial queue; no caller holds a lock while waiting.
final class LocalShortcutServer: @unchecked Sendable {
    static let shared = LocalShortcutServer()
    private let queue = DispatchQueue(label: "com.tequila.dash.shortcut-files")
    private var listener: NWListener?
    private var routes: [String: Data] = [:]
    private var pending: [UUID: (String, CheckedContinuation<URL?, Never>)] = [:]
    private var port: UInt16 = 0

    private init() {}

    func serve(fileURL: URL, as name: String) async -> URL? {
        guard !name.isEmpty, !name.contains("/"), !name.contains("\\"),
              let data = try? Data(contentsOf: fileURL) else { return nil }
        return await withCheckedContinuation { continuation in
            queue.async {
                let path = "/" + name
                self.routes[path] = data
                if self.port != 0 {
                    continuation.resume(returning: self.url(for: path))
                    return
                }
                let id = UUID()
                self.pending[id] = (path, continuation)
                self.queue.asyncAfter(deadline: .now() + 3) {
                    guard let item = self.pending.removeValue(forKey: id) else { return }
                    item.1.resume(returning: nil)
                    if self.port == 0 && self.pending.isEmpty { self.stopOnQueue() }
                }
                guard self.listener == nil else { return }
                do {
                    let parameters = NWParameters.tcp
                    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
                    let listener = try NWListener(using: parameters)
                    self.listener = listener
                    listener.newConnectionHandler = { [weak self] connection in
                        guard let self else { connection.cancel(); return }
                        self.handle(connection)
                    }
                    listener.stateUpdateHandler = { [weak self, weak listener] state in
                        guard let self, let listener, self.listener === listener else { return }
                        switch state {
                        case .ready:
                            self.port = listener.port?.rawValue ?? 0
                            self.finishPending()
                        case .failed, .cancelled:
                            self.stopOnQueue()
                        default: break
                        }
                    }
                    listener.start(queue: self.queue)
                } catch {
                    self.stopOnQueue()
                }
            }
        }
    }

    func stop() {
        queue.async { self.stopOnQueue() }
    }

    private func url(for path: String) -> URL? {
        guard port != 0 else { return nil }
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = Int(port)
        components.path = path
        return components.url
    }

    private func finishPending() {
        let items = pending.values
        pending.removeAll()
        for (path, continuation) in items { continuation.resume(returning: url(for: path)) }
    }

    private func stopOnQueue() {
        let old = listener
        listener = nil
        port = 0
        old?.cancel()
        finishPending()
        routes.removeAll()
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 5) { connection.cancel() }
        receive(connection, buffered: Data())
    }

    private func receive(_ connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            var request = buffered
            if let data { request.append(data) }
            guard error == nil, request.count <= 8192 else { connection.cancel(); return }
            guard request.range(of: Data("\r\n\r\n".utf8)) != nil else {
                if complete { connection.cancel() }
                else { self.receive(connection, buffered: request) }
                return
            }
            let line = String(data: request, encoding: .utf8)?.components(separatedBy: "\r\n").first ?? ""
            let parts = line.split(separator: " ")
            let method = parts.first.map(String.init) ?? ""
            let path = parts.count > 1 ? String(parts[1]).components(separatedBy: "?")[0] : "/"
            let body = (method == "GET" || method == "HEAD") ? self.routes[path] : nil
            let status = body == nil ? "404 Not Found" : "200 OK"
            let header = "HTTP/1.1 \(status)\r\nContent-Type: application/octet-stream\r\nContent-Length: \(body?.count ?? 0)\r\nConnection: close\r\n\r\n"
            let payload = Data(header.utf8) + (method == "HEAD" ? Data() : (body ?? Data()))
            connection.send(content: payload, completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}
