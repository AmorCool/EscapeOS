//go:build openlist_embed

// OpenList bridge（v0.3.73 方案 A：与 Sap* 共用单一 Go runtime，静态链接进宿主）.
//
// ★ v0.3.90 起默认**不再编进 App**（可拆卸化）：本文件带 openlist_embed 构建标签，
// App 构建（build-sap.sh）不传该标签 → OpenList 代码完全退出 App 二进制（瘦身 ~50MB）.
// 可拆卸形态：module-esc CI 用 `-tags "openlist_embed sqlite_cgo_compat"` 构建
// c-shared openlist.dylib，打成模块 zip（ed25519 签名）经 edge 分发，宿主 dlopen 加载.
// 需要恢复内置形态时：build-sap.sh 加回该标签即可（代码零改动）.
//
// 之前用 dlopen 加载第二个 Go runtime（openlist.dylib）——双 runtime 在进程内
// 初始化即崩（run.log 实锤：dlopen 成功 → 调用即死，Go 代码一行未执行）.
// 现改为与 SapSigner 同一 runtime：无第二 runtime，构造上消除闪退.
//
// 铁律：
//   - 绝不 os.Exit / log.Fatal —— 进程内退出 = 杀宿主.启动失败只写
//     stderr.log 然后永久阻塞（time.Sleep 不触发死锁检测）.
//   - 只能启动一次（openlistMu + openlistStarted 标志）——重复启动会导致端口冲突.
//   - 数据目录由 **调用方以参数传入**（Go env 在 runtime 初始化时已快照，宿主事后
//     setenv 对 os.Getenv 不可见）；Go stderr 与 std log 重定向到 <dataDir>/stderr.log.

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
	"syscall"
	"time"

	"github.com/OpenListTeam/OpenList/v4/cmd"
	"github.com/OpenListTeam/OpenList/v4/internal/op"
)

var (
	openlistMu      sync.Mutex
	openlistStarted bool
)

// v0.3.79 二分诊断：逐步逼近崩溃点.每步先写 <dir>/stepN.begin，完成后写 stepN.done.
// 用法（SSH）：step1 → step2 → step3 → step4，哪一步让 App 崩，凶手就在该步新增的语句里.

func stepMark(dir, name, text string) {
	_ = os.MkdirAll(dir, 0755)
	_ = os.WriteFile(filepath.Join(dir, name), []byte(text+"\n"), 0644)
}

// 仅 MkdirAll + WriteFile（对照：OpenListProbe 已验证可行）
//
//export OpenListStep1
func OpenListStep1(dirC *C.char) C.int {
	dir := C.GoString(dirC)
	// 注意：os.WriteFile 只返回 error（不是 (int, error)，那是 f.Write 的签名）
	stepMark(dir, "step1.begin", "step1 begin dir="+dir)
	err := os.WriteFile(filepath.Join(dir, "step1.test"), []byte("ok"), 0644)
	stepMark(dir, "step1.done", fmt.Sprintf("step1 done err=%v", err))
	return C.int(1)
}

// step1 + 打开 stderr.log（OpenFile）
//
//export OpenListStep2
func OpenListStep2(dirC *C.char) C.int {
	dir := C.GoString(dirC)
	stepMark(dir, "step2.begin", "step2 begin")
	_ = os.MkdirAll(dir, 0755)
	f, err := os.OpenFile(filepath.Join(dir, "stderr.log"), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0644)
	stepMark(dir, "step2.done", fmt.Sprintf("step2 done open err=%v", err))
	if err == nil {
		_ = f.Close()
	}
	return C.int(2)
}

// step2 + 替换 os.Stderr + log.SetOutput + Fprintln（不启服务）
//
//export OpenListStep3
func OpenListStep3(dirC *C.char) C.int {
	dir := C.GoString(dirC)
	stepMark(dir, "step3.begin", "step3 begin")
	_ = os.MkdirAll(dir, 0755)
	if f, err := os.OpenFile(filepath.Join(dir, "stderr.log"), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0644); err == nil {
		os.Stderr = f
		log.SetOutput(f)
		log.SetFlags(log.LstdFlags)
	}
	fmt.Fprintln(os.Stderr, "[step3] stderr redirected")
	stepMark(dir, "step3.done", "step3 done")
	return C.int(3)
}

// step3 + 真正进入 cmd.RootCmd.Execute（服务启动，会长期阻塞）
//
//export OpenListStep4
func OpenListStep4(dirC *C.char) C.int {
	dir := C.GoString(dirC)
	stepMark(dir, "step4.begin", "step4 begin")
	_ = os.MkdirAll(dir, 0755)
	if f, err := os.OpenFile(filepath.Join(dir, "stderr.log"), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0644); err == nil {
		os.Stderr = f
		log.SetOutput(f)
	}
	fmt.Fprintln(os.Stderr, "[step4] entering RootCmd.Execute")
	stepMark(dir, "step4.pre-execute", "step4 about to Execute")
	os.Args = []string{"openlist", "server", "--data", dir}
	err := cmd.RootCmd.Execute()
	stepMark(dir, "step4.done", fmt.Sprintf("step4 Execute returned err=%v", err))
	return C.int(4)
}

// OpenListAdminSet 重置 OpenList 管理员密码（走官方 CLI：openlist admin set <pwd>）.
// 返回 0=成功；-1=Execute 错误；-2=参数为空；-3=panic.
// 服务运行中也可执行：sqlite WAL 模式允许并发写入；os.Args 此时改写安全（server 已解析完）.
//
//export OpenListAdminSet
func OpenListAdminSet(pwdC, dirC *C.char) C.int {
	pwd := C.GoString(pwdC)
	dir := C.GoString(dirC)
	if pwd == "" || dir == "" {
		return C.int(-2)
	}
	done := make(chan struct{})
	ret := C.int(0)
	go func() {
		defer close(done)
		defer func() {
			if r := recover(); r != nil {
				ret = C.int(-3)
			}
		}()
		os.Args = []string{"openlist", "admin", "set", pwd, "--data", dir}
		if err := cmd.RootCmd.Execute(); err != nil {
			fmt.Fprintf(os.Stderr, "[openlist] admin set error: %v\n", err)
			ret = C.int(-1)
		}
	}()
	<-done
	return ret
}

//export OpenListAdminSetPwd
// 运行中重置管理员密码（v0.3.163 安全版）：
// 直接走 internal/op 单例（服务运行中已初始化），绕开 CLI 链——
// 旧实现 OpenListAdminSet 走 RootCmd.Execute → setAdminPassword →
// bootstrap.Init() 重复执行（InitDB 无幂等守卫）→ 二次初始化 sqlite
// → fatal，Go recover 抓不住 → 宿主闪退（真机实锤）.
// 返回 0=成功；-1=GetAdmin 失败；-2=UpdateUser 失败；-3=参数空；-4=panic.
func OpenListAdminSetPwd(pwdC, dirC *C.char) C.int {
	pwd := C.GoString(pwdC)
	if pwd == "" {
		return C.int(-3)
	}
	done := make(chan struct{})
	ret := C.int(0)
	go func() {
		defer close(done)
		defer func() {
			if r := recover(); r != nil {
				fmt.Fprintf(os.Stderr, "[openlist] admin set pwd panic: %v\n", r)
				ret = C.int(-4)
			}
		}()
		admin, err := op.GetAdmin()
		if err != nil {
			fmt.Fprintf(os.Stderr, "[openlist] GetAdmin error: %v\n", err)
			ret = C.int(-1)
			return
		}
		admin.SetPassword(pwd)
		if err := op.UpdateUser(admin); err != nil {
			fmt.Fprintf(os.Stderr, "[openlist] UpdateUser error: %v\n", err)
			ret = C.int(-2)
			return
		}
		fmt.Fprintln(os.Stderr, "[openlist] admin password updated")
	}()
	<-done
	return ret
}
//export OpenListStop
func OpenListStop() C.int {
	openlistMu.Lock()
	defer openlistMu.Unlock()
	if !openlistStarted {
		return C.int(0)
	}
	if err := syscall.Kill(syscall.Getpid(), syscall.SIGTERM); err != nil {
		return C.int(-1)
	}
	return C.int(0)
}

// OpenListMemTest 逐步申请 MB 级内存并触碰（提交物理页），返回成功申请的 MB 数.
// 用途：SSH `memtest <MB>` 探测本进程的内存天花板——若申请到某个量级 App 消失，
// 即为 iOS jetsam 硬杀（v0.3.83：用于判定 OpenList 启动期被杀是否内存所致）.
//
//export OpenListMemTest
func OpenListMemTest(mbC C.int) C.int {
	mb := int(mbC)
	if mb <= 0 {
		mb = 64
	}
	if mb > 4096 {
		mb = 4096
	}
	blocks := make([][]byte, 0, mb)
	defer func() { _ = recover() }()
	for i := 0; i < mb; i++ {
		b := make([]byte, 1024*1024)
		for j := range b {
			b[j] = 1
		}
		blocks = append(blocks, b)
	}
	runtime.GC()
	got := len(blocks)
	blocks = nil
	runtime.GC()
	return C.int(got)
}

// OpenListProbe 最小动作：确认进程内 Go 可写文件 + runtime 正常（不启服务）.
// 数据目录同样由参数传入（原因同 OpenListMain：Go 的 env 快照）.
// 写入 <dataDir>/probe.txt，返回写入字节数；失败返回 -1.
//
//export OpenListProbe
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

// GoSelfTest 只触发 Go runtime 初始化并返回固定值 42——诊断用：
// 用 SSH 的 `gotest` 命令手动调用，判断"Go runtime 能否在本环境初始化完成".
// 注意：runtime 初始化会连带跑所有已链接包的 init（含 OpenList），因此它验证的是
// 「单次 runtime 初始化」能否存活，而不是 OpenList 服务本身.
//
//export GoSelfTest
func GoSelfTest() C.int {
	return 42
}

// OpenListMain 启动进程内 OpenList 服务；永不返回（阻塞服务或永久 sleep）.
//
// 关键（v0.3.78 闪退根因修复）：数据目录必须作为 **参数** 传入，不能靠环境变量——
// Go 在 runtime 初始化时就快照了 environ，宿主事后的 setenv 对 os.Getenv 不可见，
// 导致此前 dataDir 恒为空 → 退回相对路径 ./data（错误位置），日志/数据全落错地方.
//
// 铁律：绝不 os.Exit / log.Fatal —— 进程内退出 = 杀宿主 App.
//
//export OpenListMain
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

	// ★ v0.3.85 根因修复：服务逻辑必须跑在真正的 goroutine 里，不能在
	// cgo 导出函数（C 线程）的栈上直接执行.
	//
	// 原因：宿主 pthread 直接调用导出函数时，Go 代码运行在 cgo 回调的受限栈上；
	// OpenList 数据库用 modernc/sqlite（C→Go 机器翻译产物），初始化调用层次极深，
	// 在受限栈上必然爆栈 → SIGSEGV 直接杀进程，Go 层 recover 完全抓不到，
	// 表现为"进程无声死亡、一个字都没写出来".
	//
	// goroutine 的栈从 2KB 起动态增长（上限 1GB），不会爆栈.
	// 佐证：写文件/probe/申请 1GB 内存（调用层次浅）全部成功，
	// 唯独深入 sqlite 初始化时必崩.
	done := make(chan struct{})
	go func() {
		defer close(done)
		openlistRun(dataDir)
	}()
	// openlistRun 正常会永久阻塞在 Execute（服务运行中）；
	// 若内部 panic 被 recover，done 关闭后落到下面的永久阻塞.
	<-done

	// 兜底：永久阻塞，宿主存活.
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
	// --debug/--log-std：v0.3.84 诊断——让 OpenList 把 bootstrap 每一步日志打到
	// stderr（宿主已把 fd 2 重定向到 <dataDir>/go_stderr.log），从而看到它死在哪一步.
	os.Args = []string{"openlist", "server", "--data", dataDir, "--debug", "--log-std"}
	trace("args-set")

	// 不调 cmd.Execute()——它在出错时 os.Exit(1) 会杀宿主.
	// 直接走 RootCmd：成功 = 阻塞服务中；失败 = 记录后返回（外层永久阻塞）.
	if err := cmd.RootCmd.Execute(); err != nil {
		trace("error: " + err.Error())
	} else {
		trace("execute-returned-nil")
	}
}
