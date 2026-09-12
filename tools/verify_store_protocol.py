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

    require("全口径空结果 → 换一次令牌" not in history, "empty list must not trigger login")
    require("revision=1" not in history, "invented revision fallback removed")
    require("/databases/\\(revision)/items" in history, "musr is the database id")
    require("mtco" in history and "mrco" in history, "DAAP counts validated")
    require("if needsLicense" in install and "refreshAccount" not in install.split("if needsLicense", 1)[1].split("onLog?(\"[AppleID] 请求下载信息", 1)[0], "license path does not pre-login")
    require("failedAccount: account" in install and "failedAccount: account" in history, "refresh is ticket-conditioned")
    require("private var flights" in gate and "StoreAccountRequestGate" in gate, "single-flight and account lease installed")
    require("sessionRevision" in source("vendor/ApplePackage/Models/Account.swift"), "stale account CAS marker present")
    require("missingRedirect" in protocol and "这是按出口 IP 的限流" not in protocol, "301 is not misdiagnosed as rate limiting")
    require("retryable" in protocol and "status == 301" not in protocol, "credentials are not replayed on empty 301")
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
