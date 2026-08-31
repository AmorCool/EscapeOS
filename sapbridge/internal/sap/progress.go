package sap

import (
	"fmt"
	"sync"
)

// SAP 资产准备流水线的阶段常量。宿主 App 在 SapInit 阻塞自己线程的同时，
// 从另一个线程轮询 SapGetProgress（C 导出）读取这里的状态，用于：
//   - 登录日志实时输出（下载进度 / 模拟器启动 / 握手）
//   - 「App Store 下载」页状态条（JIT 模式 + 资产包进度）
const (
	ProgressPhaseIdle        = 0 // 未开始
	ProgressPhaseDownloading = 1 // 下载 Apple 资产包（done/total 为解压字节）
	ProgressPhaseBooting     = 2 // 启动 Unicorn 模拟器
	ProgressPhaseHandshaking = 3 // SAP setup 握手（cert + exchange）
	ProgressPhaseReady       = 4 // 就绪
)

var (
	progressMu    sync.Mutex
	progressPhase = uint64(ProgressPhaseIdle)
	progressDone  uint64
	progressTotal uint64
)

// SetProgress 记录当前阶段。刻意不使用 bridgeMu——SapInit 全程持有 bridgeMu，
// 而宿主的轮询发生在那个窗口内，必须用独立的轻量锁。
func SetProgress(phase uint64, done, total uint64) {
	progressMu.Lock()
	defer progressMu.Unlock()
	progressPhase, progressDone, progressTotal = phase, done, total
}

// ProgressString 返回 "phase=<n>;done=<n>;total=<n>"。
func ProgressString() string {
	progressMu.Lock()
	defer progressMu.Unlock()
	return fmt.Sprintf("phase=%d;done=%d;total=%d", progressPhase, progressDone, progressTotal)
}
