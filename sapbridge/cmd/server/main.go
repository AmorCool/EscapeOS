// EscapeSapServer —— SAP 签名的局域网服务（跑在用户的 PC 上）。
//
// 背景（v0.3.11）：iOS 侧的 SAP 签名依赖 Unicorn TCG = JIT，无 JIT 环境
// （iOS 27 beta + StikDebug 失效）无法运行。PC（x86 Windows 原生）没有
// JIT 限制——同一套 internal/sap 代码在 Windows 上直接跑。
//
// iOS 端（RemoteSapSigner）通过局域网调用：
//   POST /v1/init  {setupURL, certURL, version, hwIDBase64}   初始化（PC 上下载资产包）
//   POST /v1/sign  <raw request body>                         → {"signature": "<base64>"}
//   POST /v1/close                                             释放模拟器
//   GET  /health                                               存活检查
//
// 安全模型：仅局域网使用，默认无鉴权；-token 可选共享口令（Header: X-Sap-Token）。
package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"sync"
	"time"

	"github.com/majd/ipatool/v2/internal/sap"
)

var (
	mu        sync.Mutex
	signer    sap.ActionSigner
	startedAt time.Time
	apiToken  string
)

type initRequest struct {
	SetupURL       string `json:"setupURL"`
	CertificateURL string `json:"certURL"`
	Version        uint32 `json:"version"`
	HWIDBase64     string `json:"hwIDBase64"`
}

func writeErr(w http.ResponseWriter, code int, err error) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(map[string]string{"error": err.Error()})
}

func writeOK(w http.ResponseWriter, payload map[string]string) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	_ = json.NewEncoder(w).Encode(payload)
}

func checkToken(r *http.Request) error {
	if apiToken == "" {
		return nil
	}
	if r.Header.Get("X-Sap-Token") == apiToken {
		return nil
	}
	return errors.New("token mismatch")
}

func handleInit(w http.ResponseWriter, r *http.Request) {
	if err := checkToken(r); err != nil {
		writeErr(w, 401, err)
		return
	}
	var req initRequest
	if err := json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(&req); err != nil {
		writeErr(w, 400, err)
		return
	}
	hw, err := base64.StdEncoding.DecodeString(req.HWIDBase64)
	if err != nil {
		writeErr(w, 400, fmt.Errorf("hwIDBase64: %w", err))
		return
	}
	if req.SetupURL == "" || req.CertificateURL == "" {
		writeErr(w, 400, errors.New("setupURL/certURL required"))
		return
	}

	mu.Lock()
	defer mu.Unlock()
	if signer != nil {
		_ = signer.Close()
		signer = nil
	}

	cfg := sap.Config{
		SetupURL:       req.SetupURL,
		CertificateURL: req.CertificateURL,
		Version:        req.Version,
		HardwareID:     hw,
	}
	// PC 上初始化：资产包下载走 PC 网络（快、无 iOS 配额），模拟器 x86 原生启动。
	started := time.Now()
	s, err := sap.NewSigner(context.Background(), cfg)
	if err != nil {
		writeErr(w, 500, fmt.Errorf("sap init: %w", err))
		return
	}
	signer = s
	startedAt = started
	log.Printf("[init] ok in %s (hw %d bytes)", time.Since(started).Round(time.Millisecond), len(hw))
	writeOK(w, map[string]string{"status": "ready"})
}

func handleSign(w http.ResponseWriter, r *http.Request) {
	if err := checkToken(r); err != nil {
		writeErr(w, 401, err)
		return
	}
	body, err := io.ReadAll(io.LimitReader(r.Body, 1<<20))
	if err != nil {
		writeErr(w, 400, err)
		return
	}

	mu.Lock()
	defer mu.Unlock()
	if signer == nil {
		writeErr(w, 409, errors.New("signer not initialized; call /v1/init first"))
		return
	}
	started := time.Now()
	sig, err := signer.Sign(body)
	if err != nil {
		writeErr(w, 500, fmt.Errorf("sign: %w", err))
		return
	}
	log.Printf("[sign] ok in %s (%d bytes body)", time.Since(started).Round(time.Millisecond), len(body))
	writeOK(w, map[string]string{"signature": base64.StdEncoding.EncodeToString(sig)})
}

func handleClose(w http.ResponseWriter, r *http.Request) {
	if err := checkToken(r); err != nil {
		writeErr(w, 401, err)
		return
	}
	mu.Lock()
	defer mu.Unlock()
	if signer != nil {
		_ = signer.Close()
		signer = nil
	}
	writeOK(w, map[string]string{"status": "closed"})
}

func handleHealth(w http.ResponseWriter, r *http.Request) {
	mu.Lock()
	ready := signer != nil
	since := startedAt
	mu.Unlock()
	payload := map[string]interface{}{"status": "ok", "ready": ready}
	if ready {
		payload["since"] = since.Format(time.RFC3339)
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	_ = json.NewEncoder(w).Encode(payload)
}

func main() {
	addr := flag.String("addr", ":8964", "listen address")
	token := flag.String("token", "", "optional shared token (X-Sap-Token header)")
	flag.Parse()
	apiToken = *token

	mux := http.NewServeMux()
	mux.HandleFunc("/health", handleHealth)
	mux.HandleFunc("/v1/init", handleInit)
	mux.HandleFunc("/v1/sign", handleSign)
	mux.HandleFunc("/v1/close", handleClose)

	log.Printf("EscapeSapServer listening on %s (token=%v)", *addr, apiToken != "")
	if err := http.ListenAndServe(*addr, mux); err != nil {
		log.Fatal(err)
	}
}
