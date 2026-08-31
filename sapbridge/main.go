package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"context"
	"encoding/base64"
	"fmt"
	"os"
	"sync"
	"unsafe"

	"github.com/majd/ipatool/v2/internal/sap"
)

// The SAP signer runs an x86-64 Unicorn emulation of Apple's private CommerceKit
// signing session entirely in-process. JIT is not required (Unicorn is an
// interpreter), but the Go runtime + libunicorn must be linked into the app and
// the process must be allowed to execute the emulated code. Under LiveContainer
// the guest is emulated, so no host JIT entitlement is needed for the guest.
//
// C API (all returned C strings must be freed by the caller via SapFree):
//
//	SapInit(setupURL, certURL *C.char, version C.int, hwIDBase64 *C.char, cacheDir *C.char) *C.char
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
func SapInit(setupURL, certURL *C.char, version C.int, hwIDBase64 *C.char, cacheDir *C.char) *C.char {
	bridgeMu.Lock()
	defer bridgeMu.Unlock()

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
func SapSign(requestBase64 *C.char) *C.char {
	bridgeMu.Lock()
	defer bridgeMu.Unlock()

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

	if signer != nil {
		_ = signer.Close()
		signer = nil
	}
	lastErr = ""
}

//export SapFree
// SapFree releases a string returned by SapInit/SapSign/SapLastError.
func SapFree(ptr *C.char) {
	if ptr != nil {
		C.free(unsafe.Pointer(ptr))
	}
}

func main() {}
