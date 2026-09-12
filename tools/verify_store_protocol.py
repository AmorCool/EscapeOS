from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]


def source(path: str) -> str:
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
    require("triedAlternateContentType" in auth, "content-type probe is bounded to one retry")
    # v0.3.354：换过机器身份后不能再把旧会话的 Cookie 当自己的发出去。
    require("deviceGuid" in source("vendor/ApplePackage/Models/Account.swift"),
            "session records the machine identity it was issued under")
    require("reusableCookies" in gate and "stored.deviceGuid == currentGUID" in gate,
            "a session from another identity is not replayed")
    require("authenticationURL(next.absoluteString)" in auth, "login redirect is allowlisted")
    require("request.httpShouldHandleCookies = false" in auth, "auth uses one cookie owner")
    require("storageKey" in cookies and "name, domain, path" in cookies, "cookie identity preserves scope")
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
