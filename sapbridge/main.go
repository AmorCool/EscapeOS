package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"sync"
	"unsafe"

	"github.com/majd/ipatool/v2/authappstore"
	"github.com/majd/ipatool/v2/internal/sap"
)

// The SAP signer runs an x86-64 Unicorn emulation of Apple's private CommerceKit
// signing session entirely in-process. Unicorn 2.x executes guest code via TCG,
// which IS a JIT on Apple platforms (pthread_jit_write_protect_np / MAP_JIT):
// a host JIT is REQUIRED, and without the entitlement the TCG write to
// executable memory kills the process (v0.3.1 注释里的 "interpreter" 说法已证伪).
// The Swift layer probes JIT (mmap MAP_JIT) BEFORE calling SapInit and refuses
// to start the emulator without it — no-JIT users get a clear "enable JIT via
// StikDebug" message instead of a crash. Apple mandates the SAP signature for
// login, so there is no unsigned fallback that can succeed.
//
// C API (all returned C strings must be freed by the caller via SapFree):
//
//	SapInit(setupURL, certURL *C.char, version C.int, hwIDBase64 *C.char, cacheDir *C.char) *C.char
//	SapGetProgress() *C.char
//
// All exported entry points recover Go-level panics and surface them as error
// strings (a panic crossing the cgo boundary would abort the whole process —
// a device crash). Native faults inside libunicorn (e.g. TCG without JIT) are
// NOT recoverable and are gated by the Swift-side JIT probe instead.
//	SapSign(requestBase64 *C.char) *C.char
//	SapLastError() *C.char
//	SapClose()
//	SapFree(ptr *C.char)

var (
	bridgeMu sync.Mutex
	signer   sap.ActionSigner
	lastErr  string
)

//export SapInit
// SapInit configures the signer. setupURL/certURL come from the App Store bag
// (sign-sap-setup / sign-sap-setup-cert). version is normally 200. hwIDBase64
// is a base64-encoded 1-20 byte hardware identifier. Returns NULL on success or
// a malloc'd error string (free with SapFree).
func SapInit(setupURL, certURL *C.char, version C.int, hwIDBase64 *C.char, cacheDir *C.char) (result *C.char) {
	bridgeMu.Lock()
	defer bridgeMu.Unlock()

	// v0.3.5：recover Go 级 panic（如依赖库越界/空指针）——跨 cgo 边界未 recover
	// 的 panic 会 abort 整个进程（真机闪退），这里转成错误字符串交给 Swift/UI。
	// 注意：libunicorn 内部的原生段错误（TCG/JIT 类）不在此列，由 JIT 闸门前置拦截。
	defer func() {
		if r := recover(); r != nil {
			lastErr = fmt.Sprintf("sap: panic in SapInit: %v", r)
			result = C.CString(lastErr)
		}
	}()

	if signer != nil {
		return C.CString("sap: already initialized; call SapClose first")
	}

	hw, err := base64.StdEncoding.DecodeString(C.GoString(hwIDBase64))
	if err != nil {
		return C.CString("sap: invalid hardware id base64: " + err.Error())
	}

	cfg := sap.Config{
		SetupURL:       C.GoString(setupURL),
		CertificateURL: C.GoString(certURL),
		Version:        uint32(version),
		HardwareID:     hw,
		CacheDir:       C.GoString(cacheDir),
	}

	s, err := sap.NewSigner(context.Background(), cfg)
	if err != nil {
		return C.CString("sap init: " + err.Error())
	}

	signer = s
	return nil
}

//export SapSign
// SapSign signs a base64-encoded request body and returns the base64-encoded
// signature, or NULL on error (inspect SapError). The returned string must be
// freed with SapFree.
func SapSign(requestBase64 *C.char) (result *C.char) {
	bridgeMu.Lock()
	defer bridgeMu.Unlock()

	defer func() {
		if r := recover(); r != nil {
			lastErr = fmt.Sprintf("sap: panic in SapSign: %v", r)
			result = nil
		}
	}()

	lastErr = ""

	if signer == nil {
		lastErr = "sap: not initialized"
		return nil
	}

	req, err := base64.StdEncoding.DecodeString(C.GoString(requestBase64))
	if err != nil {
		lastErr = "sap: decode request: " + err.Error()
		return nil
	}

	sig, err := signer.Sign(req)
	if err != nil {
		lastErr = "sap: " + err.Error()
		fmt.Fprintf(os.Stderr, "sap: sign error: %v\n", err)
		return nil
	}

	return C.CString(base64.StdEncoding.EncodeToString(sig))
}

//export SapLastError
// SapLastError returns the last error as a malloc'd string (free with SapFree),
// or NULL if the last operation succeeded. Renamed from SapError to avoid a
// clash with the Swift SapError enum in the bridging layer.
func SapLastError() *C.char {
	bridgeMu.Lock()
	defer bridgeMu.Unlock()

	if lastErr == "" {
		return nil
	}
	return C.CString(lastErr)
}

//export SapClose
// SapClose tears down the signer and releases the emulator.
func SapClose() {
	bridgeMu.Lock()
	defer bridgeMu.Unlock()

	defer func() { _ = recover() }()

	if signer != nil {
		_ = signer.Close()
		signer = nil
	}
	lastErr = ""
}

//export SapGetProgress
// SapGetProgress returns the current asset-preparation state as
// "phase=<n>;done=<n>;total=<n>". The host polls this from another thread
// while SapInit blocks its own thread (download / emulator boot / handshake).
// Uses a dedicated lock, NOT bridgeMu (which SapInit holds for its whole run).
func SapGetProgress() *C.char {
	return C.CString(sap.ProgressString())
}

//export SapFree
// SapFree releases a string returned by SapInit/SapSign/SapLastError.
func SapFree(ptr *C.char) {
	if ptr != nil {
		C.free(unsafe.Pointer(ptr))
	}
}

// ─── EscapeAppStoreLogin（v0.3.262）──────────────────────────────────────
//
// App Store 登录整体下沉到 Go 侧：直接复用上游 ipatool 的登录链路
//（authappstore 包 = pkg/appstore+pkg/http 文件级照抄），请求由 Go 标准库
// net/http/crypto-tls 发出 —— 报文形态（Content-Type: application/x-www-form-
//-urlencoded、Go TLS 指纹、头集合与顺序）与 IPARanger 捆绑的 ipatool 二进制
// 完全一致。SAP 签名器复用本进程 internal/sap 的 Unicorn guest（cacheDir 与
// Swift 侧共享，资产包只下载一次）。
//
// 参数：
//	email/password/authCode —— Apple ID 凭据（authCode 为 2FA 验证码，可空串）
//	macAddress              —— 设备标识（Swift 侧持久化的
//	                          ApplePackageDeviceIdentifier，hex 串；与 SAP
//	                          硬件标识同源，对齐上游 machineIdentity）
//	cacheDir                —— SAP 资产包缓存目录（可与 SapInit 共用）
// 返回（JSON 字符串，SapFree 释放）：
//	{"success":true,"authCodeRequired":false,"error":"",
//	 "account":{"email":...,"passwordToken":...,"directoryServicesID":...,
//	            "name":...,"storeFront":...,"pod":...},
//	 "cookies":[{"name":...,"value":...,"domain":...,"path":...}]}
//	失败时 success=false + error 文本；2FA 时 authCodeRequired=true。
//
//export EscapeAppStoreLogin
func EscapeAppStoreLogin(email, password, authCode, macAddress, cacheDir *C.char) (result *C.char) {
	// 登录是长事务（bag + SAP 初始化 + 至多 4×3 次请求）；与 SapInit 一样
	// recover 防 panic 跨 cgo 边界 abort 进程。
	defer func() {
		if r := recover(); r != nil {
			result = C.CString(escapeLoginJSON(false, false, fmt.Sprintf("go panic: %v", r), nil, nil, nil))
		}
	}()

	emailStr := C.GoString(email)
	passwordStr := C.GoString(password)
	authCodeStr := C.GoString(authCode)
	macStr := C.GoString(macAddress)
	cacheDirStr := C.GoString(cacheDir)

	acc, cookies, diags, err := authappstore.Login(emailStr, passwordStr, authCodeStr, macStr, cacheDirStr)
	if err != nil {
		authCodeRequired := errors.Is(err, authappstore.ErrAuthCodeRequired)
		msg := err.Error()
		if authCodeRequired {
			// 与 Swift 侧现役 2FA 弹窗的字符串判定保持兼容
			//（desc.contains("Authentication requires verification code")）.
			msg = "Authentication requires verification code"
		}
		return C.CString(escapeLoginJSON(false, authCodeRequired, msg, nil, nil, diags))
	}

	exported := make([]escapeCookie, 0, len(cookies))
	for _, ck := range cookies {
		exported = append(exported, escapeCookie{Name: ck.Name, Value: ck.Value, Domain: ck.Domain, Path: ck.Path})
	}
	return C.CString(escapeLoginJSON(true, false, "", &acc, exported, diags))
}

// escapeCookie 带显式 json tag（type alias 转换不继承源类型 tag，必须重写）.
type escapeCookie struct {
	Name   string `json:"name"`
	Value  string `json:"value"`
	Domain string `json:"domain"`
	Path   string `json:"path"`
}

type escapeLoginResult struct {
	Success          bool                      `json:"success"`
	AuthCodeRequired bool                      `json:"authCodeRequired"`
	Error            string                    `json:"error,omitempty"`
	Account          *authappstore.Account     `json:"account,omitempty"`
	Cookies          []escapeCookie            `json:"cookies,omitempty"`
	Diagnostics      []authappstore.DiagEntry  `json:"diagnostics,omitempty"`
}

func escapeLoginJSON(success, authCodeRequired bool, errMsg string, acc *authappstore.Account, cookies []escapeCookie, diags []authappstore.DiagEntry) string {
	payload := escapeLoginResult{
		Success:          success,
		AuthCodeRequired: authCodeRequired,
		Error:            errMsg,
		Account:          acc,
		Cookies:          cookies,
		Diagnostics:      diags,
	}
	data, err := json.Marshal(payload)
	if err != nil {
		return `{"success":false,"authCodeRequired":false,"error":"marshal result: ` + err.Error() + `"}`
	}

	return string(data)
}

func main() {}
