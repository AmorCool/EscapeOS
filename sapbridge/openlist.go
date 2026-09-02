package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"fmt"
	"log"
	"os"
	"path/filepath"
	"runtime"
	"sync"
	"time"

	"github.com/OpenListTeam/OpenList/v4/cmd"
)

// OpenList bridge（v0.3.73 方案 A：与 Sap* 共用单一 Go runtime，静态链接进宿主）。
//
// 之前用 dlopen 加载第二个 Go runtime（openlist.dylib）——双 runtime 在进程内
// 初始化即崩（run.log 实锤：dlopen 成功 → 调用即死，Go 代码一行未执行）。
// 现改为与 SapSigner 同一 runtime：无第二 runtime，构造上消除闪退。
//
// 铁律：
//   - 绝不 os.Exit / log.Fatal —— 进程内退出 = 杀宿主。启动失败只写
//     stderr.log 然后永久阻塞（time.Sleep 不触发死锁检测）。
//   - 只能启动一次（sync.Once）——重复启动会导致端口冲突。
//   - 数据目录来自环境变量 OPENLIST_DATA（Swift 侧指向 Documents/Modules/<id>/data）；
//     Go stderr 与 std log 重定向到 <dataDir>/stderr.log，供 SSH runlog 查看。

var (
	openlistMu      sync.Mutex
	openlistStarted bool
)

//export OpenListProbe
// OpenListProbe 最小动作：确认进程内 Go 可写文件 + runtime 正常（不启服务）。
// 数据目录同样由参数传入（原因同 OpenListMain：Go 的 env 快照）。
// 写入 <dataDir>/probe.txt，返回写入字节数；失败返回 -1。
func OpenListProbe(dataDirC *C.char) C.int {
	defer func() { _ = recover() }()
	dir := C.GoString(dataDirC)
	if dir == "" {
		dir = os.Getenv("OPENLIST_DATA")
	}
	if dir == "" {
		dir = "./data"
	}
	_ = os.MkdirAll(dir, 0755)
	body := fmt.Sprintf("probe ok\ndir=%s\npid=%d\ngoversion=%s\nnumcpu=%d\n",
		dir, os.Getpid(), runtime.Version(), runtime.NumCPU())
	if err := os.WriteFile(filepath.Join(dir, "probe.txt"), []byte(body), 0644); err != nil {
		return C.int(-1)
	}
	return C.int(len(body))
}

//export GoSelfTest
// GoSelfTest 只触发 Go runtime 初始化并返回固定值 42——诊断用：
// 用 SSH 的 `gotest` 命令手动调用，判断"Go runtime 能否在本环境初始化完成"。
// 注意：runtime 初始化会连带跑所有已链接包的 init（含 OpenList），因此它验证的是
// 「单次 runtime 初始化」能否存活，而不是 OpenList 服务本身。
func GoSelfTest() C.int {
	return 42
}

//export OpenListMain
// OpenListMain 启动进程内 OpenList 服务；永不返回（阻塞服务或永久 sleep）。
//
// 关键（v0.3.78 闪退根因修复）：数据目录必须作为 **参数** 传入，不能靠环境变量——
// Go 在 runtime 初始化时就快照了 environ，宿主事后的 setenv 对 os.Getenv 不可见，
// 导致此前 dataDir 恒为空 → 退回相对路径 ./data（错误位置），日志/数据全落错地方。
//
// 铁律：绝不 os.Exit / log.Fatal —— 进程内退出 = 杀宿主 App。
func OpenListMain(dataDirC *C.char) C.int {
	openlistMu.Lock()
	if openlistStarted {
		openlistMu.Unlock()
		return 0 // 幂等：已启动直接返回（宿主侧有 runningProcesses 守卫）
	}
	openlistStarted = true
	openlistMu.Unlock()

	dataDir := C.GoString(dataDirC)
	if dataDir == "" {
		dataDir = os.Getenv("OPENLIST_DATA") // 兜底（env 在 runtime 初始化后才设可能读不到）
	}
	if dataDir == "" {
		dataDir = "./data"
	}
	_ = os.MkdirAll(dataDir, 0755)
	if f, err := os.OpenFile(filepath.Join(dataDir, "stderr.log"), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0644); err == nil {
		os.Stderr = f
		log.SetOutput(f)
		log.SetFlags(log.LstdFlags)
	}
	fmt.Fprintln(os.Stderr, "[openlist] server starting (in-process, single runtime)")
	fmt.Fprintln(os.Stderr, "[openlist] dataDir="+dataDir)

	openlistRun(dataDir)

	// openlistRun 只在 panic recover 或 Execute 返回后走到这里——永久阻塞，宿主存活。
	for {
		time.Sleep(time.Hour)
	}
	return 0
}

// openlistRun runs the server with panic containment and step tracing.
func openlistRun(dataDir string) {
	_ = os.MkdirAll(dataDir, 0755)

	trace := func(stage string) {
		f, err := os.OpenFile(filepath.Join(dataDir, "trace.txt"),
			os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0644)
		if err == nil {
			fmt.Fprintf(f, "stage=%s time=%s\n", stage, time.Now().Format("15:04:05.000"))
			_ = f.Close()
		}
	}

	defer func() {
		if r := recover(); r != nil {
			trace("panic: " + fmt.Sprint(r))
		}
	}()

	trace("enter")
	os.Args = []string{"openlist", "server", "--data", dataDir}
	trace("args-set")

	// 不调 cmd.Execute()——它在出错时 os.Exit(1) 会杀宿主。
	// 直接走 RootCmd：成功 = 阻塞服务中；失败 = 记录后返回（外层永久阻塞）。
	if err := cmd.RootCmd.Execute(); err != nil {
		trace("error: " + err.Error())
	} else {
		trace("execute-returned-nil")
	}
}
