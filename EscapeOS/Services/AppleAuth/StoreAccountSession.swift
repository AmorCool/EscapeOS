import Foundation

/// Account cookie mutations are transactions. Actor reentrancy alone does not serialize awaits.
private actor StoreAccountRequestGate {
    private var owners: Set<String> = []
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    func acquire(_ email: String) async {
        if owners.insert(email).inserted { return }
        await withCheckedContinuation { continuation in
            waiters[email, default: []].append(continuation)
        }
    }

    func release(_ email: String) {
        if var queue = waiters[email], !queue.isEmpty {
            let next = queue.removeFirst()
            waiters[email] = queue.isEmpty ? nil : queue
            next.resume()
        } else {
            owners.remove(email)
        }
    }
}

enum StoreAccountSession {
    private static let gate = StoreAccountRequestGate()

    /// Only hold this lease while obtaining metadata/licenses, never while downloading/installing an IPA.
    static func withAccount<T>(email: String,
                               operation: (inout AppStoreAccount) async throws -> T) async throws -> T {
        let gateKey = email.lowercased()
        await gate.acquire(gateKey)
        do {
            try Task.checkCancellation()
            guard var account = AppStoreDownloadStore.shared.account(for: email) else {
                throw StoreAuthenticationError.accountChanged
            }
            let result: T
            do {
                result = try await operation(&account)
            } catch {
                AppStoreDownloadStore.shared.update(account)
                throw error
            }
            AppStoreDownloadStore.shared.update(account)
            await gate.release(gateKey)
            return result
        } catch {
            await gate.release(gateKey)
            throw error
        }
    }
}

/// Shared by explicit login and automatic refresh. This is an app-side backoff only.
actor StoreLoginBackoff {
    static let shared = StoreLoginBackoff()
    private var blockedUntil: [String: Date] = [:]

    func check(_ email: String) throws {
        let key = email.lowercased()
        if let until = blockedUntil[key], until > Date() {
            throw StoreAuthenticationError.cooldown(Int(ceil(until.timeIntervalSinceNow)))
        }
        blockedUntil[key] = nil
    }

    func record(_ error: StoreAuthenticationError, email: String) {
        guard let interval = error.backoffInterval else { return }
        blockedUntil[email.lowercased()] = Date().addingTimeInterval(interval)
    }

    func clear(_ email: String) { blockedUntil[email.lowercased()] = nil }
}

/// All callers refreshing the same saved session await one login, rather than replaying passwords.
actor StoreRefreshCoordinator {
    static let shared = StoreRefreshCoordinator()
    private struct Flight {
        let id: UUID
        let task: Task<AppStoreAccount, Error>
    }
    private var flights: [String: Flight] = [:]

    private func key(_ email: String) -> String { email.lowercased() }

    func refresh(email: String, code: String, failedAccount: AppStoreAccount?) async throws -> AppStoreAccount {
        try Task.checkCancellation()
        let flightKey = key(email)
        guard let stored = AppStoreDownloadStore.shared.account(for: email) else {
            throw StoreAuthenticationError.accountChanged
        }
        // Another request already refreshed the failed ticket: reuse it without another login.
        if let failedAccount, !AppStoreDownloadStore.sameSession(stored, failedAccount) {
            return stored
        }
        if let flight = flights[flightKey] { return try await flight.task.value }
        guard !stored.password.isEmpty else { throw StoreAuthenticationError.credentialsRequired }
        try await StoreLoginBackoff.shared.check(email)
        // The backoff actor await is a reentrancy point; another caller may have installed a flight.
        if let flight = flights[flightKey] { return try await flight.task.value }
        if let latest = AppStoreDownloadStore.shared.account(for: email),
           !AppStoreDownloadStore.sameSession(latest, stored) { return latest }
        let id = UUID()
        let task = Task<AppStoreAccount, Error> {
            let refreshed = try await SignedStoreAuthenticator().authenticate(
                email: stored.email, password: stored.password, code: code,
                guid: AppleIDSignInService.sapGUID(), cookies: stored.cookie)
            try Task.checkCancellation()
            return try AppStoreDownloadStore.shared.commitRefresh(refreshed, replacing: stored)
        }
        flights[flightKey] = Flight(id: id, task: task)
        do {
            let account = try await task.value
            if flights[flightKey]?.id == id { flights[flightKey] = nil }
            await StoreLoginBackoff.shared.clear(email)
            return account
        } catch {
            // Record backoff before removing the flight so reentrant callers cannot start another login.
            if let authError = error as? StoreAuthenticationError {
                await StoreLoginBackoff.shared.record(authError, email: email)
            }
            if flights[flightKey]?.id == id { flights[flightKey] = nil }
            throw error
        }
    }
}
