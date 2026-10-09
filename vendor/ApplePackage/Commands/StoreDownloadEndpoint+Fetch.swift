//
//  StoreDownloadEndpoint+Fetch.swift
//  ApplePackage
//
//  Created on 2026/6/12. (Ported from ApplePackage 1.2.7 to the shim environment)
//

import Foundation

extension StoreDownloadEndpoint {
    /// 取下载信息 —— 对齐上游的**有界**回退链（v0.3.539 全量对齐 ipatool PR #554 / Asspp `b3c8574a`）。
    ///
    /// ## 上游的真实链路（3 跳，不是 1 跳也不是无界补救）
    ///
    /// ```
    /// ① volumeStore  →  ② redownload  →  ③ updateProduct（exactly once）
    /// ```
    ///
    /// - **ipatool** `pkg/appstore/appstore_download_product.go`（PR #554 新增；本地
    ///   `P3_爱思助手_上游ipatool参考` 停在 `a9bd16c`，早于该 PR，所以那份里 grep 不到）；
    /// - **Asspp** `StoreDownloadProtocol.fetchWithFallback`（此前只有 ①②，`b3c8574a` 补 ③）。
    ///
    /// ## 此前（v0.3.361 → v0.3.537）我们错在哪
    ///
    /// 真机日志（iPhone 15 / iOS 27.0，2026-10-02）：
    ///
    /// ```
    /// 08:46:45  p25-buy/volumeStoreDownloadProduct → HTTP 200 · pod=60      ← 主端点正常
    /// 08:46:45  volumeStore 需要回退（empty-songList）→ redownload
    /// 08:46:46  目录解析到当前版本 892056523                                ← 被覆盖成当前版本
    /// 08:46:55  downloaddispatch/r/redownload → HTTP 500（耗时 9s）
    /// 08:46:56  历史版本候选 6 个（目录 · 最新 9.1）
    /// 08:47:01  候选版本全部为空包 → 退回 redownload
    /// 08:47:11  downloaddispatch/r/redownload → HTTP 502（耗时 10s，kngx 兜底页）
    /// ```
    ///
    /// 三个错处：
    /// 1. **`resolveVersion` 把版本覆盖成「当前版本」**（真因）。当前版本恰恰是该账号
    ///    **没有下载记录**的那一版 ⇒ Apple 现算授权 ⇒ 9–10s ⇒ CDN 网关兜底 502。
    ///    上游明确禁止：Asspp 的 `fetchWithFallback` 注释 ——
    ///    > A failed catalog lookup must not turn into an unpinned redownload,
    ///    > and historical requests must keep their version ID.
    /// 2. **5xx 被归一成 `emptyPackage`**，于是上层刷新会话 / 获取许可 / 重试，
    ///    每次都再撞一次 10 秒超时 —— 一次点击放大成 4 次 5xx + 10 次 volumeStore。
    /// 3. **候选版本循环进了 ApplePackage 内部**（双层循环），上游 `download` 没有候选参数。
    ///
    /// ## 现在的语义
    ///
    /// 1. 打 volumeStore（带调用方给的 `externalVersionID`，可能为空）；
    /// 2. 有包 → 立即返回；
    /// 3. 无包且 `fallbackReason` 判定为「Apple 没给包」→ 解析固定版本号，进入兜底链
    ///    （redownload / updateProduct；`ent/download` 可用时只跳过 redownload 的**网络请求**，见下）；
    ///    - 调用方给了版本 → **一直用它**（历史版本请求必须保留 version ID）；
    ///    - 没给 → 调 `resolveVersion()`；解析失败或为空 → 抛 `catalogUnavailable`；
    ///      **绝不发出不带版本号的 redownload**（那种请求会走「现算授权」并超时）；
    /// 4. redownload 若回「裸 HTTP 500（无 body）」或「`no longer available` 消息」→
    ///    用**同一个版本**打 **一次** `updateProduct`（上游 4 个必要条件见 `fetchViaUpdateProduct`）；
    /// 5. 其余一切（含带 body 的 5xx）→ 抛 `transportFailure`，原样上抛、不补救。
    ///
    /// ## redownload 条件跳过（v0.3.5xx · 调研档②「条件跳过」）
    ///
    /// 结论见 `P4_全能签逆向/_impl/调研_redownload废弃.md`：**redownload 未被上游废弃**
    /// （ipatool HEAD `cde7d00` 与 Asspp 分叉仍用它；Apple 在**已认证 bag** 里仍下发
    /// `redownloadProduct`），但在本环境**100% 裸 HTTP 500**（真机 2/2 次，白等
    /// 8.863s / 11.427s），且真机里能出包的一直是「**带版本重打 ent/download**」。
    ///
    /// 因此**跳过 redownload 这一跳的网络往返**，但**不跳过整条兜底链**：
    /// - `ent/download` 可用（bag 有端点 + kbsync 已装配）⇒ 把 redownload 的结果直接当作
    ///   「裸 HTTP 500（无 snippet）」（与真机观测一致），据此进入第三跳 `updateProduct`
    ///   （exactly once）—— 兜底仍然可达；
    /// - `ent/download` 不可用（bag 无端点 / kbsync 未装配）⇒ 原样走 redownload，
    ///   由它的失败形态决定是否 updateProduct。
    ///
    /// ## v0.3.580 修正（v0.3.579 回归）
    ///
    /// v0.3.579 曾把「跳过」写成 `entUsable` 时**提前 `throw emptyPackage`**，而该 throw 位于
    /// ②redownload / ③updateProduct **之前** ⇒ 这两条兜底在 `entUsable` 时**同时不可达**。
    /// 一旦 `ent/download` 结构性失败（端点字符串在、generator 在，但资产缺失 / 响应不合规），
    /// 下载即无任何兜底 —— 这正是「AppStore 默认 AppleID 渠道下载不了」的根因。
    /// 现在把跳过决策**下移到兜底链入口**：只跳过 redownload 的**网络请求**，兜底链保留。
    ///
    /// 回退保证：redownload / updateProduct 的实现**一行未删**；`entUsable` 时至少
    /// `updateProduct` 可达，`!entUsable` 时 redownload 可达 ⇒ **任何输入下 ≥1 条兜底可达**。
    static func fetchProductWithFallback(
        client: HTTPClient,
        account: inout AppStoreAccount,
        app: Software,
        deviceIdentifier: String,
        externalVersionID: String,
        resolveVersion: (() async throws -> String)? = nil,
        entDownloadEndpoint: String? = nil
    ) async throws -> [String: Any] {
        // v0.3.5xx：**整体耗时** —— 补上「一次 fetchProductWithFallback 到底花了多久」这个盲区。
        // 格式与 `EntDownload` / `KBSyncProvider` 的 `[计时]` 一致；函数任一出口（含 throw）都打印。
        let overallStarted = Date()
        var overallOutcome = "未完成"
        defer {
            storeLog("[计时] fetchProductWithFallback 整体 耗时="
                + "\(Self.elapsedMs(since: overallStarted))ms \(overallOutcome)")
        }

        // ⓪ **首选 `ent/download`** —— 上游把它贴在整条链的**最前面**，且是
        //    「可失败退出的附加一跳」：资产缺失 / 网络失败 / 响应不合规都**静默**
        //    落回下面的旧链，**不报错**（`appstore_download_product.go:31-70`）。
        //
        //    为什么它不是替代而是附加：`ent/download` 需要 storeagent + kbsync，
        //    这两样依赖 JIT 与本地资产，实在跑不了时就该退回旧链 ——
        //    否则一个环境问题会把整条下载链拖死。
        //
        // v0.3.5xx（本次新增）：记「首轮是否已用**非空版本**真正打过 `ent/download`」——
        // 供下方「拿到解析版本后回头重试」判定：首轮**因版本号为空被跳过** ⇒ 那次重试是
        // **首次**真正发出 ent/download 请求（不重复）；首轮已带版本打过且失败 ⇒ 不再重试
        // （避免对同一个版本重复请求）。
        var entTriedWithVersion = false
        if let endpoint = entDownloadEndpoint, !endpoint.isEmpty {
            // 版本必须固定：上游在 `sendPreferredDownload` 里，空版本会去查目录补，
            // 补不到就报错。我们这里沿用调用方给的版本；为空时**不试**这一跳
            // （`EntDownload.fetchProduct` 内部也会再拦一次），让旧链按它自己的
            // 有界回退去处理。
            //
            // v0.3.5xx（本次新增）：**调用方没给版本号时，先向宿主要「上次成功用过的
            // 版本号」，拿到就把它交给首选的 `ent/download`** —— 这样首轮就能一步到位，
            // 不必先发一次注定空包的 `volumeStore`、再白等 `redownload` 的裸 500。
            //
            // 依据（真机实测，`P4_全能签逆向/_impl/分析_前期慢时间线.md`）：
            // 首轮 `externalVersionID` 为空 ⇒ `ent/download` 被跳过 ⇒ 必然掉进
            // `volumeStore`（≈1.5s）→ `redownload` 裸 HTTP 500（白等 8.9~11.4s）；
            // 而**同一个版本号一旦带上**，`ent/download` 一次就 200 —— 两轮链路唯一
            // 差别就是版本号有无。所以「已知版本」时不该再走那段弯路。
            //
            // 保守性：宿主没装 provider / 缓存没命中 ⇒ `preferredVersion` 仍为空 ⇒
            // 下面**原样**落回旧的 `volumeStore → redownload` 链（含其内部回退），
            // 行为与改动前一致。
            var preferredVersion = externalVersionID
            if preferredVersion.isEmpty, let provider = Configuration.preferredDownloadVersionProvider {
                let lookupStarted = Date()
                let cached = await provider(account.directoryServicesIdentifier, app.bundleID)
                let lookupMs = Self.elapsedMs(since: lookupStarted)
                if let cached, !cached.isEmpty {
                    preferredVersion = cached
                    storeLog("[计时] 首轮版本预解析 耗时=\(lookupMs)ms 命中版本 \(cached)")
                } else {
                    storeLog("[计时] 首轮版本预解析 耗时=\(lookupMs)ms 未命中")
                }
            }
            if !preferredVersion.isEmpty {
                entTriedWithVersion = true
                let entStarted = Date()
                if let preferred = try await EntDownload.fetchProduct(
                    client: client,
                    account: &account,
                    app: app,
                    deviceIdentifier: deviceIdentifier,
                    externalVersionID: preferredVersion,
                    endpoint: endpoint
                ) {
                    storeLog("[计时] ent/download 首轮命中 耗时=\(Self.elapsedMs(since: entStarted))ms")
                    overallOutcome = "ent/download 命中"
                    return preferred
                }
                storeLog("[计时] ent/download 未命中 耗时=\(Self.elapsedMs(since: entStarted))ms")
            } else {
                storeLog("ent/download 跳过：版本号为空")
            }
        }

        let volumeStarted = Date()
        let primary = try await StoreDownloadEndpoint.volumeStore.fetchProduct(
            client: client,
            account: &account,
            app: app,
            deviceIdentifier: deviceIdentifier,
            externalVersionID: externalVersionID
        )
        storeLog("[计时] volumeStore 耗时=\(Self.elapsedMs(since: volumeStarted))ms")

        // 有包就直接回去 —— 这是绝大多数正常路径，一次请求结束。
        guard let reason = fallbackReason(primary) else {
            overallOutcome = "volumeStore 命中"
            return primary
        }

        storeLog("volumeStore 没有包（\(reason)）\(summary(primary))")

        // 版本解析：调用方给了就**一直用它**（Asspp: "historical requests must
        // keep their version ID"）；没给才去查目录，查不到就明确报错。
        let resolved: String
        if !externalVersionID.isEmpty {
            resolved = externalVersionID
        } else if let resolveVersion {
            do {
                resolved = try await resolveVersion()
            } catch is CancellationError {
                overallOutcome = "取消"
                throw CancellationError()
            } catch {
                storeLog("目录版本解析失败：\(error.localizedDescription)")
                overallOutcome = "catalogUnavailable"
                throw ApplePackageError.catalogUnavailable
            }
        } else {
            overallOutcome = "catalogUnavailable"
            throw ApplePackageError.catalogUnavailable
        }

        // Asspp 同款硬门：**空版本号绝不允许发出 redownload**。
        // 不带版本号的 redownload 有两个后果：可能返回 tvOS/macOS 包；
        // 而且（真机实测）会走 Apple 的「现算授权」路径，10 秒后网关兜底 502。
        guard !resolved.isEmpty else {
            overallOutcome = "catalogUnavailable"
            throw ApplePackageError.catalogUnavailable
        }

        // ── redownload 跳过决策（下移到兜底链入口，**绝不提前 throw**）────────────────
        //
        // `ent/download` 可用 = bag 给了端点 **且** 宿主装配了 kbsync 生成器。
        // 可用时：redownload 在本环境 100% 裸 HTTP 500（真机 2/2，白等 8.9~11.4s），
        // 跳过它**这一跳的网络请求**；但**整条兜底链必须保留** —— 直接按「redownload 回
        // 裸 500（无 snippet）」这一既知结果进入第三跳 updateProduct（exactly once）。
        //
        // ⚠️ v0.3.579 回归教训：曾在此处提前 `throw emptyPackage`，而它位于 ②redownload /
        // ③updateProduct 之前 ⇒ 两条兜底在 `entUsable` 时同时不可达。一旦 ent/download
        // 结构性失败即无任何兜底。所以「跳过」只能跳过**请求本身**，不能跳过**兜底链**。
        let entUsable = (entDownloadEndpoint?.isEmpty == false) && (Configuration.kbsyncGenerator != nil)

        // ⓪-b **拿到解析版本后，回头重试 `ent/download`**（v0.3.5xx 本次核心修法）。
        //
        // 场景（真机 `login.log:3-4,10-15`）：首轮 `externalVersionID` 为空 ⇒ 上面那一跳
        // 被「版本号为空」挡掉；随后 `volumeStore` 回空包，直到这里才由 `resolveVersion()`
        // 解析出真正的版本号（`StoreCatalog.externalVersionID`，真机 `版本=892324676`）。
        // **旧代码从此再没回头试 `ent/download`** —— 而是掉进 `redownload`（本环境 100% 裸
        // HTTP 500，白等 8.9~11.4s）再靠 `updateProduct` 兜底，等于把「对下架 App 最可能
        // 出包的那一跳」白白跳过。
        //
        // 现在：版本号一到手，**用同一个版本再试一次 `ent/download`**（至多一次网络往返）。
        // 命中就直接返回；未命中则**原样落回**下面的 `redownload → updateProduct` 链 ——
        // 既有兜底一行未删，所以「加了重试反而弄坏 updateProduct」不可能发生。
        //
        // 不重复请求：只在「首轮确实因版本号为空被跳过」时重试（`!entTriedWithVersion`）；
        // 首轮已带版本打过 `ent/download`（含缓存命中的版本）且失败 ⇒ 跳过重试。
        //
        // 失败一律**静默落回兜底链**（与首轮「可失败退出的附加一跳」同语义）：只有取消才上抛。
        if entUsable, !entTriedWithVersion, !resolved.isEmpty, let endpoint = entDownloadEndpoint {
            let entRetryStarted = Date()
            let rescued: [String: Any]?
            do {
                rescued = try await EntDownload.fetchProduct(
                    client: client,
                    account: &account,
                    app: app,
                    deviceIdentifier: deviceIdentifier,
                    externalVersionID: resolved,
                    endpoint: endpoint
                )
            } catch is CancellationError {
                overallOutcome = "取消"
                throw CancellationError()
            } catch {
                storeLog("ent/download 用解析版本回试失败：\(error.localizedDescription)")
                rescued = nil
            }
            if let rescued {
                storeLog("[计时] ent/download 用解析版本回试命中 耗时=\(Self.elapsedMs(since: entRetryStarted))ms 版本=\(resolved)")
                overallOutcome = "ent/download 命中（解析版本回试）"
                return rescued
            }
            storeLog("[计时] ent/download 用解析版本回试未命中 耗时=\(Self.elapsedMs(since: entRetryStarted))ms 版本=\(resolved)")
        }

        // redownload 的失败有两种形态，只有其中一种该走 updateProduct：
        //   · 裸 HTTP 500（`snippet == ""`）                  → 走 ✓
        //   · 带 body 的 5xx（如真机那个 `kngx` 502 HTML 页） → **不走** ✗
        //   · 200 + `no longer available` 消息               → 走 ✓
        // 上游 `isEmptyRedownloadError` 明确要求 `Snippet == ""`。
        var redownloadResponse: [String: Any]?
        var redownloadBodySnippet: String?   // nil 表示「裸 5xx，无 snippet」（上游 empty redownload error）
        var redownloadHTTPStatus = 200

        if entUsable {
            // 跳过 redownload 的网络往返：把结果直接当作「裸 HTTP 500」——
            // 与真机观测（本环境 redownload 100% 裸 500）一致，从而保住 updateProduct 兜底。
            storeLog("redownload 跳过（ent/download 可用）")
            redownloadHTTPStatus = 500
            redownloadBodySnippet = nil
        } else {
            storeLog("redownload 兜底（ent/download 不可用）")
            storeLog("redownload 使用版本 \(resolved)")
            let redownloadStarted = Date()
            do {
                redownloadResponse = try await StoreDownloadEndpoint.redownload.fetchProduct(
                    client: client,
                    account: &account,
                    app: app,
                    deviceIdentifier: deviceIdentifier,
                    externalVersionID: resolved
                )
            } catch let error as ApplePackageError {
                overallOutcome = "redownload 抛 ApplePackageError"
                throw error
            } catch let error as StoreAuthenticationError {
                overallOutcome = "redownload 抛 StoreAuthenticationError"
                throw error
            } catch is CancellationError {
                overallOutcome = "取消"
                throw CancellationError()
            } catch {
                // 走到这里 = HTTP 层失败。我们只关心「裸 500」这一档，其余原样上抛。
                let (status, snippet) = Self.classifyBareHTTPFailure(error)
                redownloadHTTPStatus = status
                redownloadBodySnippet = snippet
            }
            storeLog("[计时] redownload 耗时=\(Self.elapsedMs(since: redownloadStarted))ms"
                + "（HTTP \(redownloadHTTPStatus)）")
        }

        if let response = redownloadResponse {
            storeLog("redownload 返回；\(summary(response))")
            // 200 + `no longer available` 消息 → 还有一次 updateProduct 机会。
            if Self.isNoLongerAvailable(response) {
                storeLog("redownload 回 No Longer Available")
                if let rescued = try await fetchViaUpdateProduct(
                    client: client, account: &account, app: app,
                    deviceIdentifier: deviceIdentifier, externalVersionID: resolved
                ) {
                    storeLog("updateProduct 命中；\(summary(rescued))")
                    overallOutcome = "updateProduct 命中"
                    return rescued
                }
                storeLog("updateProduct 没有包")
                overallOutcome = "emptyPackage"
                throw ApplePackageError.emptyPackage
            }
            // 普通业务性空包 → 没有第三跳（上游同款）。
            if let reason = fallbackReason(response) {
                storeLog("redownload 没有包（\(reason)）")
                overallOutcome = "emptyPackage"
                throw ApplePackageError.emptyPackage
            }
            overallOutcome = "redownload 命中"
            return response
        }

        // HTTP 层失败：只有「裸 500（无 snippet）」按上游语义有资格走 updateProduct。
        if redownloadHTTPStatus == 500, redownloadBodySnippet == nil {
            storeLog("redownload 裸 HTTP 500（无 body）")
            if let rescued = try await fetchViaUpdateProduct(
                client: client, account: &account, app: app,
                deviceIdentifier: deviceIdentifier, externalVersionID: resolved
            ) {
                storeLog("updateProduct 命中；\(summary(rescued))")
                overallOutcome = "updateProduct 命中"
                return rescued
            }
            storeLog("updateProduct 没有包")
            overallOutcome = "emptyPackage"
            throw ApplePackageError.emptyPackage
        }

        // 其余 HTTP 失败（带 body 的 4xx/5xx 如 kngx 502、429、网络错误）**原样上抛** ——
        // 它们是传输层/服务端状态，不是「Apple 没包给你」，伪装成 emptyPackage 只会
        // 诱发上层刷新会话 / 获取许可的连环补救（真机一次点击放大成 4 次 5xx + 10 次 volumeStore）。
        storeLog("redownload HTTP \(redownloadHTTPStatus) 原样上抛")
        overallOutcome = "transportFailure(\(redownloadHTTPStatus))"
        throw ApplePackageError.transportFailure(status: redownloadHTTPStatus)
    }

    /// v0.3.5xx：`[计时]` 日志用 —— 与锚点的毫秒差（`LoginLogger` 自己已带绝对时间戳，
    /// 这里只让「每段耗时」一眼可见，补上「全链路逐请求耗时=0」这个盲区）。
    private static func elapsedMs(since start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1000)
    }

    /// 把 HTTP 层错误分类成「裸 5xx（无 body） / 带 body 的失败」。
    ///
    /// 上游判据（`isEmptyRedownloadError`）：
    /// ```go
    /// var unexpected *http.UnexpectedResponseError
    /// return errors.As(err, &unexpected) &&
    ///     unexpected.StatusCode == gohttp.StatusInternalServerError &&
    ///     unexpected.Snippet == ""
    /// ```
    /// ⇒ **只有 `500` 且 `snippet` 为空**才算「空 redownload 错误」。返回 `(500, nil)`。
    /// 其它任何情况返回 `(status, snippet非nil)`。
    private static func classifyBareHTTPFailure(_ error: Error) -> (Int, String?) {
        let ns = error as NSError
        guard ns.domain == "EscapeOS.Ensure" else {
            // 非 Ensure 域（网络层等）→ 没有可信状态码，按「不可用第三跳」处理。
            let code = ns.code > 0 ? ns.code : -1
            return (code, "(non-ensure)")
        }
        let text = ns.localizedDescription
        // ensureFailed("store fetch failed with status \(code)") / "store fetch failed: HTTP \(code) …"
        for token in text.split(whereSeparator: { !$0.isNumber }) {
            if let code = Int(token), (100 ... 599).contains(code) {
                // 带 body 的 5xx？Ensure 文案里出现 "body=" 说明有 snippet。
                let hasBody = text.contains("body=")
                return (code, hasBody ? "(has body)" : nil)
            }
        }
        return (-1, "(unparsable)")
    }

    /// 上游 `isUnavailableDownloadProductResponse` 的 Swift 版：
    /// 200 + `failureType` 空 + `items` 空 + `customerMessage` 是 "no longer available"。
    static func isNoLongerAvailable(_ response: [String: Any]) -> Bool {
        guard (response["failureType"] as? String ?? "").isEmpty else { return false }
        guard (response["songList"] as? [Any])?.isEmpty ?? true else { return false }
        let message = (response["customerMessage"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return message == "no longer available" || message.hasSuffix(" no longer available")
    }

    /// updateProduct 端点取包（上游 `sendUpdateProduct`）。
    ///
    /// **调用方必须已经确认 4 个前置条件**（bag 有端点 / 版本非空 / iOS 平台 / redownload
    /// 是裸 500 或 No-Longer-Available）—— 本函数只负责发请求与校验响应。
    ///
    /// 响应校验严格对齐上游：
    /// - `failureType` 非空 → 原样返回（保留结构化失败给上层解释）；
    /// - `customerMessage` 非空 → 报错；
    /// - 状态码非 200 → 报错；
    /// - **`songList` 必须恰好 1 项**（上游 `len(res.Data.Items) != 1` → error）；
    /// - 该项的 `itemId` 与请求 app 一致、`softwareVersionExternalIdentifier` 与请求版本一致；
    /// - `softwareVersionBundleId` 与 app 的 bundleID 一致。
    ///
    /// - Returns: 校验通过的响应字典；任一步失败返回 `nil`（让调用方走原结论）。
    static func fetchViaUpdateProduct(
        client: HTTPClient,
        account: inout AppStoreAccount,
        app: Software,
        deviceIdentifier: String,
        externalVersionID: String
    ) async throws -> [String: Any]? {
        // v0.3.5xx：**补计时** —— 此前 updateProduct 这一跳没有耗时读数（真机日志里只有
        // 「试 updateProduct」与结果，看不到它花了多久）。格式对齐 `EntDownload` 的 `[计时]`。
        let started = Date()
        var outcome = "未命中"
        defer {
            storeLog("[计时] updateProduct 耗时=\(Self.elapsedMs(since: started))ms \(outcome)")
        }
        do {
            let dict = try await StoreDownloadEndpoint.updateProduct.fetchProduct(
                client: client,
                account: &account,
                app: app,
                deviceIdentifier: deviceIdentifier,
                externalVersionID: externalVersionID
            )
            storeLog("updateProduct 返回；\(summary(dict))")
            // 结构化失败（failureType 非空）→ 上游也是原样返回，这里按「没拿到包」处理。
            if !(dict["failureType"] as? String ?? "").isEmpty { return nil }
            if !(dict["customerMessage"] as? String ?? "").isEmpty { return nil }
            guard let items = dict["songList"] as? [[String: Any]], items.count == 1,
                  let metadata = items[0]["metadata"] as? [String: Any]
            else {
                storeLog("updateProduct 响应 songList 不是恰好 1 项")
                return nil
            }
            // itemId 与请求 app 一致
            if let itemID = metadata["itemId"], "\(itemID)" != "\(app.id)" {
                storeLog("updateProduct 响应的 itemId 不匹配")
                return nil
            }
            // softwareVersionExternalIdentifier 与请求版本一致
            if let ext = metadata["softwareVersionExternalIdentifier"],
               "\(ext)" != externalVersionID {
                storeLog("updateProduct 响应的版本不匹配")
                return nil
            }
            // bundleID 一致（app.bundleID 非空时才校验）
            if let bundle = metadata["softwareVersionBundleId"] as? String, !app.bundleID.isEmpty,
               bundle != app.bundleID {
                storeLog("updateProduct 响应的 bundleID 不匹配")
                return nil
            }
            outcome = "命中"
            return dict
        } catch is CancellationError {
            outcome = "取消"
            throw CancellationError()
        } catch {
            storeLog("updateProduct 请求失败：\(error.localizedDescription)")
            outcome = "请求失败"
            return nil
        }
    }


    /// 是否需要换端点重取（对齐 Asspp dev 的 fallbackReason）
    static func fallbackReason(_ response: [String: Any]) -> String? {
        if response["failureType"] as? String == retryableFailureType {
            return "failure-5002"
        }
        // 有明确的业务错误 → 是真实拒绝，不要换端点重试
        guard (response["failureType"] as? String ?? "").isEmpty,
              (response["customerMessage"] as? String ?? "").isEmpty,
              response["dialog"] == nil, response["action"] == nil
        else { return nil }
        if let status = response["status"] as? Int, status != 0 { return nil }
        if let status = response["status"] as? String, !status.isEmpty, status != "0" { return nil }
        if let items = response["songList"] as? [Any] {
            return items.isEmpty ? "empty-songList" : nil
        }
        return response["songList"] == nil ? "missing-songList" : nil
    }

    /// 结构化摘要 —— 只报字段形态与数字码，便于定位又不泄露内容
    static func summary(_ response: [String: Any]) -> String {
        let failure = response["failureType"] as? String ?? ""
        let message = response["customerMessage"] as? String ?? ""
        let items: String
        if let list = response["songList"] as? [Any] {
            items = "\(list.count)"
        } else {
            items = response["songList"] == nil ? "missing" : "invalid"
        }
        let status: String
        if let value = response["status"] as? Int { status = "\(value)" }
        else if let value = response["status"] as? String, !value.isEmpty { status = value }
        else { status = "none" }
        let shown = message.count <= 160 ? message : String(message.prefix(160)) + "…"
        return "songList=\(items) failure=\(failure.isEmpty ? "none" : failure) "
            + "status=\(status) customerMessage=\(message.isEmpty ? "none" : shown) "
            + "dialog=\(response["dialog"] != nil) action=\(response["action"] != nil)"
    }

    /// 对单个端点发起 product 请求，处理 pod 重定向，解析返回 plist。
    func fetchProduct(
        client: HTTPClient,
        account: inout AppStoreAccount,
        app: Software,
        deviceIdentifier: String,
        externalVersionID: String
    ) async throws -> [String: Any] {
        // v0.3.5xx：**补耗时** —— 单端点请求（volumeStore / redownload / updateProduct 共用）
        // 此前只有一行「响应头行」，没有「这次请求本身花了多久」（含重定向与 plist 解析）。
        // 格式对齐 `EntDownload` 的 `[计时]`；函数任一出口（含 throw）都打印。
        let requestStarted = Date()
        var requestOutcome = "未完成"
        defer {
            storeLog("[计时] \(self.host)\(path) 单端点请求 耗时="
                + "\(StoreDownloadEndpoint.elapsedMs(since: requestStarted))ms \(requestOutcome)")
        }

        var currentURL = try url(pod: account.pod, deviceIdentifier: deviceIdentifier)
        var redirectAttempt = 0
        var finalResponse: HTTPClient.Response?
        let maxRedirects = 3

        while redirectAttempt <= maxRedirects {
            let request = try makeRequest(
                account: account,
                app: app,
                url: currentURL,
                deviceIdentifier: deviceIdentifier,
                externalVersionID: externalVersionID
            )
            try Task.checkCancellation()
            let response = try await client.execute(request: request).get()
            finalResponse = response
            account.cookie.mergeCookies(response.cookies)
            if let pod = response.headers.first(name: "pod"), Int(pod) != nil { account.pod = pod }
            if let store = response.headers.first(name: "X-Set-Apple-Store-Front"), !store.isEmpty {
                account.fullStoreFront = store
            }

            if (300 ... 399).contains(response.status.code) {
                guard redirectAttempt < maxRedirects,
                      let location = response.headers.first(name: "location"), !location.isEmpty,
                      let next = URL(string: location, relativeTo: currentURL)?.absoluteURL,
                      next != currentURL else {
                    throw StoreAuthenticationError.invalidRedirect
                }
                currentURL = try StoreAuthenticationProtocol.storeURL(next.absoluteString,
                    paths: [StoreDownloadEndpoint.volumeStore.path,
                            StoreDownloadEndpoint.redownload.path,
                            StoreDownloadEndpoint.updateProduct.path])
                redirectAttempt += 1
                continue
            }
            break
        }

        guard let finalResponse else {
            requestOutcome = "无响应"
            try ensureFailed("no response received")
        }
        requestOutcome = "HTTP \(finalResponse.status.code)"

        // v0.3.336：把 Apple 侧能表明原因的响应头记下来（App 内日志）。
        // 排查「静默空包」时最有用的是 `X-Apple-Request-Store-Front`（Apple 回显它认到的
        // storefront，`<null>` 表示没认到）与 Set-Cookie 数（会话是否被接受）。
        let rsf = finalResponse.headers.first(name: "x-apple-request-store-front") ?? "(无)"
        let podHeader = finalResponse.headers.first(name: "pod") ?? "-"
        let cookieCount = finalResponse.cookies.count
        storeLog("\(self.host)\(path) → HTTP \(finalResponse.status.code) · "
                 + "X-Apple-Request-Store-Front=\(rsf) · pod=\(podHeader) · Set-Cookie=\(cookieCount)")

        guard finalResponse.status == .ok else {
            let code = finalResponse.status.code
            let ct = finalResponse.headers.first(name: "content-type") ?? "(unknown)"
            let bodyData = finalResponse.body?.data ?? Data()
            let snippet = String(data: bodyData.prefix(512), encoding: .utf8) ?? "(非 UTF-8)"
            storeLog("store fetch failed: HTTP \(code) ct=\(ct) body=\(snippet.prefix(200))")
            if code == 429 {
                // v0.3.365：**明确识别限流**。不能归一成 `emptyPackage` —— 那会让上层以为「没有包」
                // 而转进购买/刷新流程，继续放大请求（verhist 审计：一次动作最坏 38 次，叠加后会自持）；
                // 也不能让它以裸状态码抛出去（原来会变成「invalid response status 429」这种看不懂的硬失败）。
                // 直接抛可识别的限流错误：上层不重试、不降级，把准确原因交给用户。
                let retryAfter = StoreAuthenticationProtocol.retryAfter(
                    finalResponse.headers.first(name: "Retry-After"))
                storeLog("Apple 下载服务限流 HTTP 429")
                throw StoreAuthenticationError.rateLimited(retryAfter: retryAfter)
            }
            if code == 401 || code == 403 {
                // 会话票据被拒 → 交给上层重登一次再试（对齐 ipatool/Asspp 的 401/403 语义）。
                throw ApplePackageError.passwordTokenExpired
            }
            if (500 ... 599).contains(code) {
                // v0.3.352：5xx（redownload 常见 500/502 空 body）就是「Apple 没有包给你」，
                // 归一成 emptyPackage，让上层去「获取许可」补救；不再抛裸 HTTP 字符串错误。
                throw ApplePackageError.emptyPackage
            }
            try ensureFailed("store request failed with status \(code)")
        }

        guard var body = finalResponse.body,
              let data = body.readData(length: body.readableBytes)
        else {
            requestOutcome = "HTTP 200 响应体为空"
            try ensureFailed("response body is empty")
        }

        let plist = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) as? [String: Any]
        guard let dict = plist else {
            requestOutcome = "HTTP 200 响应不是合法 plist"
            try ensureFailed("invalid plist response")
        }

        requestOutcome = "HTTP 200 解析成功"
        return dict
    }

    private func makeRequest(
        account: AppStoreAccount,
        app: Software,
        url: URL,
        deviceIdentifier: String,
        externalVersionID: String
    ) throws -> HTTPClient.Request {
        var payload: [String: Any] = [
            "creditDisplay": "",
            "guid": deviceIdentifier,
            "salableAdamId": app.id,
            // v0.3.334：回到 `"0"`。上游两个可用的实现都发 "0"
            // （ipatool PR #500：Apple 对热门应用给 volumeStore 加了校验，补
            //   serialNumber 且**用 "0" 就能过**；Asspp StoreDownloadProtocol.payload 同款 "0"）。
            // 我们 v0.3.301 曾改成 `Configuration.deviceSerialNumber`（本机真序列号），
            // 理由是"sinf 要绑本机证书"——但那时没有任何可用的 Apple ID 登录，整条链路
            // 都是盲写的。真机实测（v0.3.331 日志）：带真序列号时 volumeStore 回空包、
            // redownload 回 HTTP 500，链路走不下去。
            "serialNumber": "0",
        ]

        if !externalVersionID.isEmpty {
            payload[externalVersionIDKey] = externalVersionID
        }

        let data = try PropertyListSerialization.data(fromPropertyList: payload, format: .xml, options: 0)

        var headers: [(String, String)] = [
            ("Content-Type", "application/x-apple-plist"),
            ("User-Agent", Configuration.userAgent),
            // v0.3.334：Asspp 的下载请求带 Accept-Language，补上（客户端保真度）
            ("Accept-Language", Locale.preferredLanguages.prefix(3).joined(separator: ", ")),
            ("iCloud-DSID", account.directoryServicesIdentifier),
            ("X-Dsid", account.directoryServicesIdentifier),
        ]
        // v0.3.336：带上 storefront（与购买同款写法）。实测它不改变 Apple 的给包结果，
        // 但能让响应头 `X-Apple-Request-Store-Front` 回显真实值 —— 排查空包时这行是关键证据
        // （不回显 `<null>` 只能说明「请求没声明区域」，看不出账号到底认的哪个区）。
        if !account.store.isEmpty {
            headers.append(("X-Apple-Store-Front", account.requestStoreFront))
        }

        for item in account.cookie.buildCookieHeader(url) {
            headers.append(item)
        }

        return try HTTPClient.Request(
            url: url,
            method: .POST,
            headers: HTTPHeaders(headers),
            body: .data(data)
        )
    }
}
