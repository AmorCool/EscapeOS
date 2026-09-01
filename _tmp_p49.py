import io

def patch(path, old, new, count=1):
    s = io.open(path, encoding='utf-8').read().replace('\r\n', '\n')
    assert s.count(old) == count, (path, old[:60], s.count(old), s.count(old))
    io.open(path, 'w', encoding='utf-8', newline='\n').write(s.replace(old, new))

# ① PiP：对齐原版三处（音频会话激活 / canStartAutomatically / background task）
p = 'EscapeOS/Services/PiPKeepAliveService.swift'

patch(p,
'''    /// KVO：等待 isPictureInPicturePossible（异步置 true，原版同款）
    private var possibleObservation: NSKeyValueObservation?
    private var startWatchdog: DispatchWorkItem?''',
'''    /// KVO：等待 isPictureInPicturePossible（异步置 true，原版同款）
    private var possibleObservation: NSKeyValueObservation?
    private var startWatchdog: DispatchWorkItem?

    /// 后台任务桥（原版 beginBackgroundTaskIfNeeded："PiPKeepAlive"）
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    private func beginBackgroundTaskIfNeeded() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "PiPKeepAlive") { [weak self] in
            self?.endBackgroundTaskIfNeeded()
        }
    }

    private func endBackgroundTaskIfNeeded() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }''')

patch(p,
'''            let pip = AVPictureInPictureController(contentSource: source)
            pip.delegate = self
            pipController = pip
            contentVC = vc''',
'''            let pip = AVPictureInPictureController(contentSource: source)
            pip.delegate = self
            // 原版 updatePiPAutomaticStartPolicy：回后台自动进 PiP
            pip.canStartPictureInPictureAutomaticallyFromInline = true
            pipController = pip
            contentVC = vc''')

patch(p,
'''        guard let pip = pipController else { return }

        // 音频会话激活（后台保活加成）
        try? AVAudioSession.sharedInstance().setActive(true)
        lastError = nil
        intentionalStop = false''',
'''        guard let pip = pipController else { return }

        // 原版实锤：.playback + mixWithOthers + setActive——
        // "start with active playback so PiP is possible immediately"
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: .mixWithOthers)
        try? AVAudioSession.sharedInstance().setActive(true)
        lastError = nil
        intentionalStop = false''')

patch(p,
'''        if pip.isPictureInPicturePossible {
            pip.startPictureInPicture()
            return
        }''',
'''        if pip.isPictureInPicturePossible {
            pip.startPictureInPicture()
            beginBackgroundTaskIfNeeded()
            return
        }''')

patch(p,
'''            DispatchQueue.main.async {
                self.possibleObservation?.invalidate()
                self.possibleObservation = nil
                self.startWatchdog?.cancel()
                self.startWatchdog = nil
                if !(observed.isPictureInPictureActive) {
                    observed.startPictureInPicture()
                }
            }''',
'''            DispatchQueue.main.async {
                self.possibleObservation?.invalidate()
                self.possibleObservation = nil
                self.startWatchdog?.cancel()
                self.startWatchdog = nil
                if !(observed.isPictureInPictureActive) {
                    observed.startPictureInPicture()
                    self.beginBackgroundTaskIfNeeded()
                }
            }''')

patch(p,
'''    func stop() {
        intentionalStop = true
        possibleObservation?.invalidate()
        possibleObservation = nil
        startWatchdog?.cancel()
        startWatchdog = nil
        pipController?.stopPictureInPicture()
    }''',
'''    func stop() {
        intentionalStop = true
        possibleObservation?.invalidate()
        possibleObservation = nil
        startWatchdog?.cancel()
        startWatchdog = nil
        pipController?.stopPictureInPicture()
        endBackgroundTaskIfNeeded()
    }''')

# didStop：不自动恢复时释放后台任务
patch(p,
'''    func pictureInPictureControllerDidStopPictureInPicture(_ c: AVPictureInPictureController) {
        DispatchQueue.main.async {
            self.isPiPActive = false
            // 意外停止自动恢复（用户手动关 PiP 视为意外——保活语义下自动拉起）
            if !self.intentionalStop && self.autoRestoreRemaining > 0 {
                self.autoRestoreRemaining -= 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                    guard let self, !(self.pipController?.isPictureInPictureActive ?? true) else { return }
                    print("[PiP] 意外停止，自动恢复（剩余 \\(self.autoRestoreRemaining) 次）")
                    self.start()
                }
            }
        }
    }''',
'''    func pictureInPictureControllerDidStopPictureInPicture(_ c: AVPictureInPictureController) {
        DispatchQueue.main.async {
            self.isPiPActive = false
            // 意外停止自动恢复（系统杀 PiP → 自动拉起；用户点「停止」不恢复）
            if !self.intentionalStop && self.autoRestoreRemaining > 0 {
                self.autoRestoreRemaining -= 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                    guard let self, !(self.pipController?.isPictureInPictureActive ?? true) else { return }
                    print("[PiP] 意外停止，自动恢复（剩余 \\(self.autoRestoreRemaining) 次）")
                    self.start()
                }
            } else if self.intentionalStop {
                self.endBackgroundTaskIfNeeded()
            }
        }
    }''')

print('① PiP 原版三处对齐完成')

# ② 模块：宿主 build 变化（覆盖安装新 IPA）→ 清卸载记录，内置模块回归
p2 = 'EscapeOS/Services/ModuleService.swift'
patch(p2,
'''    /// 用户主动卸载过的模块 id（防止内置模块重启后自动回归）
    private static let uninstalledKey = "Module.uninstalled.ids"''',
'''    /// 用户主动卸载过的模块 id（防止内置模块重启后自动回归）
    private static let uninstalledKey = "Module.uninstalled.ids"
    /// 卸载记录对应的宿主 build——build 变化（覆盖安装新 IPA）即清空记录
    private static let hostBuildAtUninstallKey = "Module.uninstalled.hostBuild"''')

patch(p,
'''    private func bootstrapBundledModules() {
        guard let bundledURL = Bundle.main.url(forResource: "BundledModules", withExtension: nil) else { return }
        guard let ids = try? FileManager.default.contentsOfDirectory(atPath: bundledURL.path) else { return }
        let uninstalled = uninstalledIds''',
'''    private func bootstrapBundledModules() {
        // 覆盖安装新 IPA（build 变化）→ 清空卸载记录，内置模块回归
        // 原理：覆盖安装不清 app 沙盒数据（UserDefaults 保留），
        // 所以卸载标记要绑定宿主版本——版本一变即视为用户重新装机意图
        let currentBuild = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        let recordedBuild = UserDefaults.standard.string(forKey: Self.hostBuildAtUninstallKey)
        if recordedBuild == nil {
            UserDefaults.standard.set(currentBuild, forKey: Self.hostBuildAtUninstallKey)
        } else if recordedBuild != currentBuild {
            UserDefaults.standard.removeObject(forKey: Self.uninstalledKey)
            UserDefaults.standard.set(currentBuild, forKey: Self.hostBuildAtUninstallKey)
            print("[Module] 宿主 build 变化（\\(recordedBuild ?? "?") → \\(currentBuild)），清空卸载记录")
        }

        guard let bundledURL = Bundle.main.url(forResource: "BundledModules", withExtension: nil) else { return }
        guard let ids = try? FileManager.default.contentsOfDirectory(atPath: bundledURL.path) else { return }
        let uninstalled = uninstalledIds''')

print('② 模块回归机制完成')
