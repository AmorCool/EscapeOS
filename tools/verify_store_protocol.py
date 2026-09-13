from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]


def strip_comments(text: str) -> str:
    """去掉 Swift 注释后再做子串断言。

    v0.3.359 发现（jsbox-re 变异测试 C 组实测）：本脚本原来是对**源码全文**做存在性匹配，
    于是把要断言的代码片段「留在注释里」就能骗过校验 —— 它不是行为测试，只是文本契约。
    先剥掉注释，至少让「注释能满足断言」这条捷径失效。

    v0.3.359 二次修复：早先的实现用 `re.sub(r"/\\*.*?\\*/", "", text, flags=re.S)` 剥块注释 ——
    那是**跨行非贪婪**正则，仓库里 `PurchaseHistoryService.swift` 的 `("Accept", "*/*")` 字面量
    就提供了一个 `/*`，只要它之后**任何地方**再出现一个 `*/`（哪怕只是正常块注释），
    正则会从那里一路吞到 `*/`（jsbox-re 实测静默删除 11,027 字符，`prepare()` 全体消失，
    既能造成假 FAIL 也能造成**假 PASS**）。

    现在改成**单遍扫描器**，显式跟踪「普通字符串 / 三引号多行串 / 行注释 / 块注释」四种状态：
    字符串内的 `//`、`/*`、`*/*` 一律原样保留，块注释按 `*/` 正确闭合，不再跨行误吞。
    """
    out: list[str] = []
    i, n = 0, len(text)
    in_line = in_block = in_str = in_multiline = False
    while i < n:
        ch = text[i]
        nxt = text[i + 1] if i + 1 < n else ""
        if in_line:
            if ch == "\n":
                in_line = False
                out.append(ch)
            i += 1
            continue
        if in_block:
            if ch == "*" and nxt == "/":
                in_block = False
                i += 2
                continue
            i += 1
            continue
        if in_multiline:
            if text.startswith('"""', i):
                in_multiline = False
                out.append('"""')
                i += 3
                continue
            out.append(ch)
            i += 1
            continue
        if in_str:
            out.append(ch)
            if ch == "\\" and nxt:
                out.append(nxt)
                i += 2
                continue
            if ch == '"':
                in_str = False
            i += 1
            continue
        if text.startswith('"""', i):
            in_multiline = True
            out.append('"""')
            i += 3
            continue
        if ch == '"':
            in_str = True
            out.append(ch)
            i += 1
            continue
        if ch == "/" and nxt == "/":
            in_line = True
            i += 2
            continue
        if ch == "/" and nxt == "*":
            in_block = True
            i += 2
            continue
        out.append(ch)
        i += 1
    return "".join(out)


def source(path: str) -> str:
    return strip_comments((ROOT / path).read_text(encoding="utf-8"))


def raw_source(path: str) -> str:
    """未剥注释的原文 —— 只给「必须在注释里写明」这类**文档性**断言用。"""
    return (ROOT / path).read_text(encoding="utf-8")


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def dmap(name: str, payload: bytes) -> bytes:
    return name.encode("ascii") + len(payload).to_bytes(4, "big") + payload


def walk(data: bytes, depth: int = 0):
    require(depth <= 16, "DAAP recursion bound")
    offset = 0
    while offset < len(data):
        require(len(data) - offset >= 8, "truncated DAAP header rejected")
        name = data[offset:offset + 4].decode("ascii")
        length = int.from_bytes(data[offset + 4:offset + 8], "big")
        require(length <= len(data) - offset - 8, "truncated DAAP payload rejected")
        payload = data[offset + 8:offset + 8 + length]
        yield name, payload
        if name in {"adbs", "adsr", "mlcl", "mlit"}:
            yield from walk(payload, depth + 1)
        offset += 8 + length


def main() -> None:
    history = source("EscapeOS/Engine/PurchaseHistoryService.swift")
    install = source("EscapeOS/Engine/AppStoreLocalInstallService.swift")
    auth = source("EscapeOS/Services/AppleAuth/SignedStoreAuthenticator.swift")
    protocol = source("EscapeOS/Services/AppleAuth/StoreAuthenticationProtocol.swift")
    gate = source("EscapeOS/Services/AppleAuth/StoreAccountSession.swift")
    cookies = source("vendor/ApplePackage/Supplement/Cookie.swift")
    shim = source("vendor/ApplePackage/Supplement/AsyncHTTPClientShim.swift")
    purchase = source("vendor/ApplePackage/Commands/Purchase.swift")
    fetch = source("vendor/ApplePackage/Commands/StoreDownloadEndpoint+Fetch.swift")

    # v0.3.352：Apple 用 `mstt=200 + mtco=0` 表达「这张表是空的」，而票据不被认可时
    # 也是同样的合法空表（不是 401）。因此**允许空表刷新一次会话后重试** ——
    # 但必须是单次、有日志可循，绝不能退回早先那种「换令牌 + 多口径轮询」的重登风暴。
    require("刷新一次会话后重试" in history, "empty DAAP table retries once with a refreshed session")
    require("沿用空结果" in history, "a failed refresh degrades to the empty result, not an error")
    require(history.count("AppleIDSignInService.rotate") <= 2, "at most one refresh per code path")
    require("全口径空结果" not in history, "legacy multi-variant probing removed")
    require("revision=1" not in history, "invented revision fallback removed")
    require("/databases/\\(revision)/items" in history, "musr is the database id")
    require("mtco" in history and "mrco" in history, "DAAP counts validated")

    # 下载许可链路：9610 与静默空包必须走同一段补救逻辑，且循环有界、刷新有界。
    require("if needsLicense" not in install, "empty-package branch is not dead code again")
    require("catch ApplePackageError.licenseRequired where !licensed" in install, "9610 triggers license acquisition")
    require("catch ApplePackageError.emptyPackage where !licensed" in install, "empty package triggers license acquisition")
    require("emptyRetried" in install and "刷新会话后重试" in install, "empty package confirms the session before buying")
    require("catch ApplePackageError.passwordTokenExpired where !refreshed" in install, "expired ticket refreshes once")
    require("attempt <= 6" in install, "download retry loop is bounded")
    require("acquireLicense(software:" in install, "download and UI share one license helper")
    require("failedAccount: account" in install and "failedAccount: account" in history, "refresh is ticket-conditioned")
    require("private var flights" in gate and "StoreAccountRequestGate" in gate, "single-flight and account lease installed")
    require("sessionRevision" in source("vendor/ApplePackage/Models/Account.swift"), "stale account CAS marker present")

    # Apple 对 buyProduct 回 2002（"Your password has changed."）时票据就是不被认可的，
    # 必须按 expiry 处理，否则「空包 → 获取许可」永远拿不到授权。
    require('case "2002"' in purchase, "2002 is treated as an expired ticket")
    require("password has" in purchase, "password-changed message is treated as an expired ticket")
    require("emptyPackage" in fetch and "passwordTokenExpired" in fetch, "download endpoints classify 5xx / 401 correctly")
    require("missingRedirect" in protocol and "这是按出口 IP 的限流" not in protocol, "301 is not misdiagnosed as rate limiting")
    require("retryable" in protocol and "status == 301" not in protocol, "credentials are not replayed on empty 301")
    # v0.3.353：认证重试必须对齐 ipatool —— 204 / 404 / 5xx（+ 3xx 无 Location），最多 3 次，
    # 每次用同一份 body 重新签名，延迟 250ms × 第几次。
    require("status == 204" in protocol and "status == 404" in protocol and "(500 ... 599)" in protocol,
            "authentication retries mirror ipatool (204/404/5xx)")
    require("hasRedirect" in protocol and "hasRedirect: hasRedirect" in auth,
            "3xx without Location is retried instead of failing outright")
    require("maxAttempts = 3" in auth, "authentication retry count is bounded at 3")
    require("retryDelay" in protocol and "250 * attempt" in protocol, "retry backoff matches ipatool")
    require("Retry-After" in auth, "429 is not replayed")
    require("primaryContentType" in protocol and "alternateContentType" in protocol,
            "edge rejections are probed with the alternate Content-Type")
    require(auth.count("alternateContentType") == 1, "content-type probe is bounded to one retry")
    require("storeClientAccept" in protocol and "Accept" in auth,
            "the store client Accept header is sent on the authentication request")
    require("trailingSlashVariant" in protocol and auth.count("trailingSlashVariant") == 1,
            "the trailing-slash endpoint variant is probed exactly once")
    require("nativeFastAuthenticationURL" in protocol and "ladder.append((native" in auth,
            "the native/fast endpoint is the FIRST login candidate (JAsspp order)")
    require("nativeFastURL" in protocol and 'hasSuffix("/fast")' in protocol,
            "bag-provided native endpoints are normalized to /auth/v1/native/fast/")
    # v0.3.359：native 档必须也带 store-client 的 Accept，否则①档同时差 host+Accept 两个变量，
    # 失败无法归因；已购侧的 SAP 校验必须与登录侧同样放宽。
    require("isNativeFastHost(authHost)" in auth,
            "the native rung also carries the store-client Accept header")
    # v0.3.360：3xx 拿不到可用 Location 必须走「进下一档」，不能当场 throw 打断阶梯。
    require("advanceRung" in auth and "无可用 Location" in auth,
            "a 3xx without a usable Location advances the ladder instead of aborting")
    # v0.3.361：空包必须先用候选 externalVersionId 重打 volumeStore（真机实测唯一决定性变量）。
    require("versionCandidates" in fetch and "versionCandidates.prefix(6)" in fetch,
            "an empty package retries volumeStore with candidate external version IDs")
    require("candidateVersionIDs" in install and "versionHistoryFromCatalog" in install,
            "the candidate version IDs come from the free version catalog")
    require("cachedVersionID" in install and "rememberVersionID" in install,
            "the last good externalVersionId is cached and tried first")
    require("isAppleHost" in history and "fallbackSAPCertURL" in history,
            "the purchase-history SAP signer uses the same relaxed host check as login")
    # 反向断言：已购侧的 host pin 必须**不存在**（与登录侧那条 keep-in-sync）。
    require('publicURL(value("sign-sap-setup-cert"), host:' not in history
            and 'publicURL(value("sign-sap-setup"), host:' not in history,
            "the purchase-history SAP host pin is gone")
    require("isDeviceGUID" in protocol and "guid.count == 12" not in auth,
            "device guid accepts the 12-32 hex form used by the reference client")
    # v0.3.358：SAP 端点只做「https + Apple 域」校验，不 pin 具体 host（上游 appstore_bag.go:89-94
    # 只查 https + host 非空）。硬编码兜底只作最后手段，不再是 host pin 失败后的唯一出路。
    require("fallbackSAPCertURL" in protocol and "fallbackSAPSetupURL" in protocol,
            "SAP endpoints keep a last-resort fallback")
    require("isAppleHost" in protocol and "publicSAPURL(certificateValue)" in auth,
            "SAP endpoints are validated by Apple domain, not a pinned host")
    require('publicSAPURL(value("sign-sap-setup-cert"), host:' not in auth,
            "the pinned-host SAP check is gone")
    # v0.3.358：403 / 429 不纳入重试（上游只重试 204/404/5xx；真机日志 429、403 状态码 0 次）。
    require("status == 403" not in protocol and "status == 429" not in protocol,
            "403 / 429 are not replayed (no evidence they are transient)")
    # v0.3.358：native-first 是 JAsspp 的放宽，不是 ipatool 上游行为，代码里要写明这一点。
    require("不是 ipatool 上游行为" in raw_source("EscapeOS/Services/AppleAuth/StoreAuthenticationProtocol.swift")
            and "不是 ipatool 上游行为" in raw_source("EscapeOS/Services/AppleAuth/SignedStoreAuthenticator.swift"),
            "the native-first ladder is documented as a JAsspp-only divergence")
    # v0.3.354：换过机器身份后不能再把旧会话的 Cookie 当自己的发出去。
    require("deviceGuid" in source("vendor/ApplePackage/Models/Account.swift"),
            "session records the machine identity it was issued under")
    require("reusableCookies" in gate and "stored.deviceGuid == currentGUID" in gate,
            "a session from another identity is not replayed")
    require("authenticationURL(next.absoluteString)" in auth, "login redirect is allowlisted")
    require("request.httpShouldHandleCookies = false" in auth, "auth uses one cookie owner")
    # 只断言**代码符号**（原先还断言了一句只存在于注释里的 "(name, domain, path)" —— 剥注释后暴露为假断言）
    require("storageKey" in cookies and "normalizedDomain" in cookies,
            "cookie identity preserves scope (name + domain + path)")
    require("parseResponse" in shim and "HTTPCookie.cookies" in shim, "multi-cookie parser uses Foundation")
    require("redirectConfiguration: .disallow" in purchase, "purchase POST redirects are explicit")
    require("StoreAuthenticationProtocol.storeURL" in purchase and "StoreAuthenticationProtocol.storeURL" in fetch, "credential redirects are allowlisted")

    empty = dmap("adbs", dmap("mstt", (200).to_bytes(4, "big")) + dmap("mtco", (0).to_bytes(4, "big")) + dmap("mrco", (0).to_bytes(4, "big")))
    tags = dict(walk(empty))
    require(int.from_bytes(tags["mstt"], "big") == 200, "valid DAAP status parsed")
    require(int.from_bytes(tags["mtco"], "big") == 0 and int.from_bytes(tags["mrco"], "big") == 0, "valid empty DAAP is a result")
    try:
        list(walk(empty[:-1]))
    except AssertionError:
        pass
    else:
        raise AssertionError("truncated DAAP accepted")

    print("store protocol offline checks: PASS")


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(f"store protocol offline checks: FAIL: {exc}", file=sys.stderr)
        raise
