import io

def patch(path, old, new):
    s = io.open(path, encoding='utf-8').read().replace('\r\n', '\n')
    assert s.count(old) == 1, (path, old[:70], s.count(old))
    io.open(path, 'w', encoding='utf-8', newline='\n').write(s.replace(old, new))

p = 'EscapeOS/Views/ProcessManagerView.swift'

# ① refresh() 回退：立即显示进程，内存异步后补
old_refresh = '''    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        Task.detached(priority: .utility) { [weak self] in
            do {
                let entries = try ProcessManagerService.shared.listProcesses()

                // v0.3.37：带 5 秒超时的内存查询（sysmontap next_sample 是阻塞式的，
                // 用 semaphore + background queue 防止挂死刷新流程）
                var memMap: [Int32: UInt64] = [:]
                let semaphore = DispatchSemaphore(value: 0)
                DispatchQueue.global(qos: .utility).async {
                    do {
                        memMap = try ProcessManagerService.shared.fetchMemoryUsage()
                    } catch {
                        print("[ProcessManager] 内存查询失败: \\(error.localizedDescription)")
                    }
                    semaphore.signal()
                }
                let timeoutResult = semaphore.wait(timeout: .now() + 5)
                if timeoutResult == .timedOut {
                    print("[ProcessManager] 内存查询超时（5s），跳过")
                }

                // 合并内存数据到 entries
                var enriched = entries
                for i in enriched.indices {
                    if let mem = memMap[Int32(enriched[i].pid)] {
                        enriched[i].memoryBytes = Int64(mem)
                    }
                }

                await MainActor.run {
                    guard let self else { return }
                    self.processes = enriched
                    self.isRefreshing = false
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.alertItem = ProcessAlert(title: "加载进程失败", message: error.localizedDescription)
                    self.isRefreshing = false
                }
            }
        }
    }'''
new_refresh = '''    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        Task.detached(priority: .utility) { [weak self] in
            do {
                // v0.3.38：先立即显示进程列表（不再等内存查询，避免几秒空白）
                let entries = try ProcessManagerService.shared.listProcesses()
                await MainActor.run {
                    guard let self else { return }
                    self.processes = entries
                    self.isRefreshing = false
                }
                // 内存异步后补（不阻塞刷新流程）
                self?.fetchMemoryAsync()
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.alertItem = ProcessAlert(title: "加载进程失败", message: error.localizedDescription)
                    self.isRefreshing = false
                }
            }
        }
    }

    /// v0.3.38：内存查询完全异步——独立 Task + 独立队列，绝不阻塞进程列表。
    /// sysmontap next_sample 阻塞式 → 5 秒超时保护；失败静默（胶囊显示 "—"）。
    private func fetchMemoryAsync() {
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let memMap = (try? ProcessManagerService.shared.fetchMemoryUsage()) ?? [:]
            await MainActor.run {
                guard let self else { return }
                guard !self.processes.isEmpty else { return }
                for i in self.processes.indices {
                    if let mem = memMap[Int32(self.processes[i].pid)] {
                        self.processes[i].memoryBytes = Int64(mem)
                    }
                }
            }
        }
    }'''
assert s := open(p, encoding='utf-8').read().replace('\r\n', '\n'), 'read fail'
assert s.count(old_refresh) == 1, ('refresh', s.count(old_refresh))
s = s.replace(old_refresh, new_refresh)

# ② fetchMemoryUsage 不用 operationQueue.sync → memoryQueue.sync
old_q = '''    func fetchMemoryUsage() throws -> [Int32: UInt64] {
        try operationQueue.sync {'''
new_q = '''    func fetchMemoryUsage() throws -> [Int32: UInt64] {
        // v0.3.38：不用 operationQueue.sync（sysmontap 阻塞式会卡死串行队列）
        try memoryQueue.sync {'''
assert s.count(old_q) == 1, ('queue', s.count(old_q))
s = s.replace(old_q, new_q)

# ③ 加 memoryQueue
old_mem = '''    private let operationQueue = DispatchQueue(label: "com.ipaside.escapeos.processmgr", qos: .userInitiated)'''
new_mem = '''    private let operationQueue = DispatchQueue(label: "com.ipaside.escapeos.processmgr", qos: .userInitiated)
    /// v0.3.38：内存查询专用串行队列（sysmontap 阻塞式，不与其他操作争用）
    private let memoryQueue = DispatchQueue(label: "com.ipaside.escapeos.processmgr.memory", qos: .utility)'''
assert s.count(old_mem) == 1, ('memqueue', s.count(old_mem))
s = s.replace(old_mem, new_mem)

# ④ sysmontap_next_sample 加 5 秒超时保护
old_next = '''            if let err = sysmontap_next_sample(sysmon, &processes, &system, &cpu) {
                throw error(from: err, fallback: "获取内存样本失败")
            }'''
new_next = '''            // next_sample 阻塞式 → 5 秒超时保护
            let sampleSemaphore = DispatchSemaphore(value: 0)
            var sampleError: Error?
            DispatchQueue.global(qos: .utility).async {
                var p: plist_t? = nil, s: plist_t? = nil, c: plist_t? = nil
                if let err = sysmontap_next_sample(sysmon, &p, &s, &c) {
                    sampleError = self.error(from: err, fallback: "获取内存样本失败")
                } else {
                    processes = p; system = s; cpu = c
                }
                sampleSemaphore.signal()
            }
            if sampleSemaphore.wait(timeout: .now() + 5) == .timedOut {
                sysmontap_stop(sysmon)
                return [:]  // 超时直接返回空，不抛错（保持列表可用）
            }
            if let sampleError { throw sampleError }'''
assert s.count(old_next) == 1, ('next', s.count(old_next))
s = s.replace(old_next, new_next)

io.open(p, 'w', encoding='utf-8', newline='\n').write(s)
print('v0.3.38 进程管理回退 + 异步化完成')
