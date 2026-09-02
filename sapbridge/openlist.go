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

//export OpenListMain
// OpenListMain starts the OpenList server in-process. It blocks forever while
// serving and never returns via os.Exit — startup errors are logged to
// <dataDir>/stderr.log and the thread parks (host app stays alive).
func OpenListMain() C.int {
	openlistMu.Lock()
	if openlistStarted {
		openlistMu.Unlock()
		return 0 // 已启动：幂等返回（宿主侧有 runningProcesses 守卫，正常到不了这里）
	}
	openlistStarted = true
	openlistMu.Unlock()

	dataDir := os.Getenv("OPENLIST_DATA")
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

	openlistRun()

	// openlistRun 只在 panic 被 recover 后才会走到这之后——永久阻塞，
	// 宿主存活、错误已在 stderr.log。
	for {
		time.Sleep(time.Hour)
	}
	return 0
}

// openlistRun runs the server with panic containment. Never os.Exit.
func openlistRun() {
	defer func() {
		if r := recover(); r != nil {
			fmt.Fprintf(os.Stderr, "[openlist] panic recovered: %v\n", r)
		}
	}()

	dataDir := os.Getenv("OPENLIST_DATA")
	if dataDir == "" {
		dataDir = "./data"
	}
	os.Args = []string{"openlist", "server", "--data", dataDir}

	// 不调 cmd.Execute()——它在出错时 os.Exit(1) 会杀宿主。
	// 直接走 RootCmd：成功 = 阻塞服务中；失败 = 记录后返回（外层永久阻塞）。
	if err := cmd.RootCmd.Execute(); err != nil {
		fmt.Fprintf(os.Stderr, "[openlist] server exited with error: %v\n", err)
		fmt.Fprintln(os.Stderr, "[openlist] host kept alive (never os.Exit)")
	}
}
