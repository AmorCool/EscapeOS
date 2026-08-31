package unicorn

import (
	"context"
	"testing"
	"time"
)

// TestTCISmoke 在 CI macOS host（arm64）上用 TCI（QEMU TCG 解释器）编译版
// libunicorn 实跑一段 x86-64 代码，实锤「无 JIT 环境可运行」——TCI 的执行路径
// 不写可执行内存（纯 C 解释循环），iOS 侧载 / LiveContainer 访客无 JIT 时
// 依赖的就是它。若本测试失败，说明 TCI 构建或解释路径有问题，禁止发版。
func TestTCISmoke(t *testing.T) {
	eng, err := New(context.Background())
	if err != nil {
		t.Fatalf("uc_open: %v", err)
	}
	defer func() { _ = eng.Close() }()

	const base = uint64(0x400000)
	const size = uint64(0x1000)
	if err := eng.MemMap(base, size); err != nil {
		t.Fatalf("MemMap: %v", err)
	}

	// mov eax, 42（B8 立即数低 32 位写入会零扩展到 RAX；不带 ret——
	// ret 会从未映射栈弹返回地址导致 UC_ERR_READ_UNMAPPED，纯干扰项）
	code := []byte{0xB8, 0x2A, 0x00, 0x00, 0x00}
	if err := eng.MemWrite(base, code); err != nil {
		t.Fatalf("MemWrite: %v", err)
	}

	// 执行到 begin+len(code) 即停（RIP 抵达 until 地址自然退出），30s 超时兜底
	if err := eng.StartBounded(base, base+uint64(len(code)), 30*time.Second, 0); err != nil {
		t.Fatalf("Start: %v", err)
	}

	eax, err := eng.RegRead(RegRAX)
	if err != nil {
		t.Fatalf("RegRead: %v", err)
	}
	if eax != 42 {
		t.Fatalf("RAX = %d, want 42（TCI 解释执行结果不符）", eax)
	}
}
