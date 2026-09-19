// ─────────────────────────────────────────────────────────────────────────────
//  A-64 第一步验证 harness（**临时**：验证通过后连同 workflow 一起删除）
//
//  要回答的唯一问题：
//    把 macOS 的 AirTrafficHost **x86_64 切片** + bundle 里那份 **10.9 CoreFP**
//    一起喂给 Unicorn 解释执行，能不能调通 Grappa 生成函数
//    `_uhO2GULXwfgKwPcp4YR2`，拿到 err=0 / outLen=84。
//
//  判据（唯一一条）：
//    RAX(err) == 0 且 outLen == 84，且这 84 字节非全零。
//
//  用法：
//    a64_verify <CoreFP 路径> <AirTrafficHost 路径> [CoreFP.icxs 路径]
//    两个路径都可以是 fat（universal）—— MachImage::Open 自己切 x86-64 片。
//
//  ⚠️ 本 harness 不接进 App、不新增 UI、不碰 SapMachine / SapShims 的既有行为。
//     它只复用 MachImage + SapShims 这两个**本来就独立**的类。
//     验证通过后，同样的逻辑再落成 EscapeOS/Services/AppleAuth/SAP/GrappaMachine.*。
//
//  ⚠️ 为什么调用签名是 4 个参数（SysV：rdi/rsi/rdx/rcx）：
//     从 AirTrafficHost 自己的调用点反汇编钉死的（_ATHostConnectionSendSyncRequest @0x10a0）：
//       0x001107  lea rdi, [rbx+0x50]     ; 12 字节输入
//       0x001113  mov rsi, r13            ; r13 = &conn[0x5c] → sessionId (int, in/out)
//       0x00110b  lea rdx, [rbp-0x80]     ; outPtr (void**)
//       0x00110f  lea rcx, [rbp-0x78]     ; outLen (uint32*)
//       0x001116  call 0x4db20
//       0x00111b  test eax, eax
//     即：int f(const uint8_t in12[12], int *sessionIdInOut, void **outPtr, uint32_t *outLen)
// ─────────────────────────────────────────────────────────────────────────────

#include "MachImage.h"
#include "SapMachine.h"          // 只为 SapShims（它是独立可复用的类）

#include <unicorn/unicorn.h>

#include <cstdio>
#include <cstring>
#include <fstream>
#include <stdexcept>
#include <string>
#include <vector>

// ─── 基址布局：与 SapMachine.cpp:187-198 同款，只多一个 kATHostBase ────────────
//
// ★ 关于「两个镜像的 __TEXT vmaddr 都是 0 会不会撞车」：
//   MachImage 的 Load() 把镜像映射到**调用方给的 loadBase**，段内偏移是
//   `loadBase + (seg.vmaddr - imageBase_)`。CoreFP 与 ATH 的 imageBase_ 都是 0，
//   但两者的 loadBase 不同（下面两个常量），所以**不会算出同一段地址**。
//   更强的保证：MachImage.cpp:22 把单镜像跨度硬封在 MAX_IMG_SPAN = 256 MiB，
//   而这里两个基址相距 3 GiB ⇒ **可证不重叠**。
//   另外 Unicorn 的 uc_mem_map 对已映射区间会直接返回错误 ——
//   所以「两次 Load() 都成功」本身就是「区间不重叠」的运行时证据（见 main 里的打印）。
static constexpr uint64_t kCoreFPBase = 0x0000100000000000ULL;
static constexpr uint64_t kATHostBase = 0x00001000C0000000ULL;  // = kKitBase + 0x40000000，空槽
static constexpr uint64_t kScratchBase = 0x0000300000000000ULL;
static constexpr uint64_t kScratchSize = uint64_t(32) << 20;
static constexpr uint64_t kHeapBase    = 0x0000400000000000ULL;
static constexpr uint64_t kHeapSize    = uint64_t(64) << 20;
static constexpr uint64_t kStackBase   = 0x0000500000000000ULL;
static constexpr uint64_t kStackSize   = uint64_t(8) << 20;
static constexpr uint64_t kStackEnd    = kStackBase + kStackSize;
static constexpr uint64_t kReturnAddr  = 0x0000000100000000ULL;
static constexpr uint64_t kPageSize    = 0x1000;

// SapMachine.cpp:210 kTimeout = 60'000 ms。Grappa 是纯计算，给足 60 秒；
// 若真的跑满，说明路径里有死循环或缺失的 shim（会以 fault 形式报出来）。
static constexpr uint64_t kTimeoutUs = uint64_t(60'000) * 1000;

// CoreFP 的公开导出名（10.9 那份的 export trie 恰好这 6 个，全部 n_type=0x0f）。
// 这里**只用于打印诊断**，不做「ATH 需要哪几个」的假设 ——
// ATH 要哪几个名字由它自己在运行时 dlsym 决定，见 SapShims 的 _dlsym 桩。
static const char* kCoreFPExportNames[] = {
    "_WIn9UJ86JKdV4dM", "_X46O5IeS",         "_YlCJ3lg",
    "_dku592fbFAj",     "_fdjkDSAFjklaf2s",  "_lxpgvVMLd0S7uRl",
};

static void check(uc_err err, const char* what) {
    if (err != UC_ERR_OK)
        throw std::runtime_error(std::string(what) + ": " + uc_strerror(err));
}

static std::vector<uint8_t> ReadFile(const std::string& path) {
    std::ifstream in(path, std::ios::binary);
    if (!in) throw std::runtime_error("cannot open " + path);
    in.seekg(0, std::ios::end);
    const auto size = in.tellg();
    in.seekg(0, std::ios::beg);
    std::vector<uint8_t> data(static_cast<size_t>(size));
    if (size > 0) in.read(reinterpret_cast<char*>(data.data()), size);
    if (!in) throw std::runtime_error("short read on " + path);
    return data;
}

// 与 SapMachine::Invoke 同款：SysV 传参 + 在 kReturnAddr 处放 HLT 作停止哨兵。
//
// ★ 故障判定顺序**刻意照抄 SapMachine::Invoke**（SapMachine.cpp:748-762）：
//   先 BeforeInvoke() 清上一次的 fault → emu_start → 先查 HasFault()、再查 RIP。
//   为什么顺序重要：未注册的 import 会被 Resolve 建成「抛异常桩」，
//   它的 handler 在 Dispatch 里被 catch 后走 Fail() → uc_emu_stop。
//   此时 emu_start 返回的仍是 UC_ERR_OK，但 RIP 停在半路。
//   如果先查 RIP，报出来的是「停在 0x…」；先查 HasFault() 才能报出
//   「到底是哪个 import 没注册」—— 这是第一次跑 CI 最需要的信息。
static uint64_t Invoke(uc_engine* uc, SapShims& shims, uint64_t fn,
                       uint64_t a0, uint64_t a1, uint64_t a2, uint64_t a3) {
    static constexpr int kArgRegs[4] = {UC_X86_REG_RDI, UC_X86_REG_RSI,
                                        UC_X86_REG_RDX, UC_X86_REG_RCX};
    shims.BeforeInvoke();

    const uint64_t args[4] = {a0, a1, a2, a3};
    for (int i = 0; i < 4; ++i) check(uc_reg_write(uc, kArgRegs[i], &args[i]), "write arg reg");

    // 栈：对齐到 16n+8（模拟「刚执行完 call」的状态），再压入返回哨兵
    uint64_t rsp = kStackEnd - 8;
    if (rsp % 16 != 8) rsp -= 8;
    check(uc_mem_write(uc, rsp, &kReturnAddr, 8), "push return addr");
    check(uc_reg_write(uc, UC_X86_REG_RSP, &rsp), "write RSP");

    const uc_err err = uc_emu_start(uc, fn, kReturnAddr, kTimeoutUs, 0);
    if (err != UC_ERR_OK) {
        if (shims.HasFault()) throw std::runtime_error(shims.TakeFault());
        throw std::runtime_error(std::string("uc_emu_start: ") + uc_strerror(err));
    }
    if (shims.HasFault()) throw std::runtime_error(shims.TakeFault());

    uint64_t rip = 0;
    check(uc_reg_read(uc, UC_X86_REG_RIP, &rip), "read RIP");
    if (rip != kReturnAddr) {
        char buf[32];
        std::snprintf(buf, sizeof(buf), "%#llx", (unsigned long long)rip);
        throw std::runtime_error(std::string("guest stopped at ") + buf +
                                 ", 不是 HLT 哨兵（无 shim fault ⇒ 多半是跑飞或超时）");
    }

    uint64_t rax = 0;
    check(uc_reg_read(uc, UC_X86_REG_RAX, &rax), "read RAX");
    return rax;
}

static uint64_t ReadU64(uc_engine* uc, uint64_t addr) {
    uint64_t v = 0;
    check(uc_mem_read(uc, addr, &v, 8), "read u64");
    return v;
}

static uint32_t ReadU32(uc_engine* uc, uint64_t addr) {
    uint32_t v = 0;
    check(uc_mem_read(uc, addr, &v, 4), "read u32");
    return v;
}

static void HexDump(const std::vector<uint8_t>& b) {
    for (size_t i = 0; i < b.size(); i += 16) {
        std::printf("    %04zx  ", i);
        for (size_t j = i; j < i + 16 && j < b.size(); ++j) std::printf("%02x ", b[j]);
        std::printf("\n");
    }
}

// ─── 已知结构核对 ───────────────────────────────────────────────────────────
//
// 依据：`ref-attraffic协议.md` §13.1（看雪 2018 样本：固定 84 字节，开头 `01 01`）
//       + memory `2026-09-19.md` §22（macOS 侧 3/3 样本一致的布局）：
//   [0..1]   = 01 01            常量
//   [2..17]  = 16 字节          每次不同
//   [18..19] = u16LE，高 14 位 == 0x4000，低 2 位是 flag
//              （实测出现过 0x4003 / 0x4001 / 0x4000）
//   [20..83] = 64 字节          每次不同
//
// ★ 注意偏移是**十进制字节偏移**（18..19 就是 0x12..0x13）。
// ★ 2 + 16 + 2 + 64 = 84 —— 分区长度之和恰好等于总长，这本身就独立佐证了分区正确。
//
// 为什么值得做这个核对：`err=0 / outLen=84` 是**弱判据** —— 项目历史实验
// （CHANGELOG.md:631）证明「84 字节全 0」与「`01 01`+82 个 0」在真机上也返回成功。
// 只有结构对得上，才能把「真 Grappa」与「空壳成功」分开。
static bool AllZero(const std::vector<uint8_t>& b, size_t from, size_t to) {
    for (size_t i = from; i < to; ++i) if (b[i]) return false;
    return true;
}

static bool CheckStructure(const std::vector<uint8_t>& b, const char* tag) {
    bool ok = true;
    if (b.size() != 84) {
        std::printf("  ✗ %s 长度 = %zu，期望 84\n", tag, b.size());
        return false;
    }

    // [0..1] 常量 01 01
    if (b[0] != 0x01 || b[1] != 0x01) {
        std::printf("  ✗ %s [0..1] = %02x %02x，期望 01 01\n", tag, unsigned(b[0]), unsigned(b[1]));
        ok = false;
    } else {
        std::printf("  ★ %s [0..1]   = 01 01 ✓（常量）\n", tag);
    }

    // [2..17] 16 字节可变段
    if (AllZero(b, 2, 18)) {
        std::printf("  ✗ %s [2..17]  16 字节全 0\n", tag);
        ok = false;
    } else {
        std::printf("  ★ %s [2..17]  16 字节非全零 ✓\n", tag);
    }

    // [18..19] u16LE，高 14 位应为 0x4000
    const uint16_t w  = static_cast<uint16_t>(b[18]) | (static_cast<uint16_t>(b[19]) << 8);
    const uint16_t hi = w & 0xFFFCu;
    if (hi != 0x4000u) {
        std::printf("  ✗ %s [18..19] = %#06x，高 14 位 = %#06x ≠ 0x4000\n",
                    tag, unsigned(w), unsigned(hi));
        ok = false;
    } else {
        std::printf("  ★ %s [18..19] = %#06x ✓（高 14 位 0x4000，低 2 位 flag = %u）\n",
                    tag, unsigned(w), unsigned(w & 0x0003u));
    }

    // [20..83] 64 字节可变段
    if (AllZero(b, 20, 84)) {
        std::printf("  ✗ %s [20..83] 64 字节全 0\n", tag);
        ok = false;
    } else {
        std::printf("  ★ %s [20..83] 64 字节非全零 ✓\n", tag);
    }
    return ok;
}

// ─── 单次调用 ───────────────────────────────────────────────────────────────
struct CallResult {
    int32_t              err    = 0;
    uint64_t             outPtr = 0;
    uint32_t             outLen = 0;
    uint32_t             sid    = 0;
    std::vector<uint8_t> blob;
};

static CallResult RunGrappaOnce(uc_engine* uc, SapShims& shims, uint64_t fn,
                                const uint8_t in12[12],
                                uint64_t inAddr, uint64_t sidAddr,
                                uint64_t outAddr, uint64_t lenAddr) {
    // 每次调用前把 4 个字段重置干净 —— 否则第二次会读到第一次的残留值，
    // 把「没写」误判成「写对了」。
    const uint32_t zero32 = 0;
    const uint64_t zero64 = 0;
    check(uc_mem_write(uc, inAddr,  in12, 12), "write in12");
    check(uc_mem_write(uc, sidAddr, &zero32, 4), "write sessionId=0");
    check(uc_mem_write(uc, outAddr, &zero64, 8), "write outPtr=0");
    check(uc_mem_write(uc, lenAddr, &zero32, 4), "write outLen=0");

    CallResult r;
    r.err    = static_cast<int32_t>(Invoke(uc, shims, fn, inAddr, sidAddr, outAddr, lenAddr));
    r.outLen = ReadU32(uc, lenAddr);
    r.outPtr = ReadU64(uc, outAddr);
    r.sid    = ReadU32(uc, sidAddr);

    // 立刻把 blob 拷出来：第二次调用会再 malloc，虽然当前堆分配器只递增游标、
    // 不会覆盖第一次的块，但依赖这一点太脆。
    if (r.err == 0 && r.outLen > 0 && r.outLen <= (1u << 20) && r.outPtr != 0) {
        r.blob.resize(r.outLen);
        check(uc_mem_read(uc, r.outPtr, r.blob.data(), r.blob.size()), "read grappa blob");
    }
    return r;
}

int main(int argc, char** argv) {
    if (argc < 3) {
        std::fprintf(stderr, "usage: %s <CoreFP> <AirTrafficHost> [CoreFP.icxs]\n", argv[0]);
        return 2;
    }
    const std::string coreFPPath = argv[1];
    const std::string athPath    = argv[2];
    const std::string icxsPath   = argc > 3 ? argv[3] : "";

    // 设备 GrappaSupportInfo 的实测值：{version=1, deviceType=0, protocolVersion=1}
    const uint8_t in12[12] = {0x01, 0x00, 0x00, 0x00,
                              0x00, 0x00, 0x00, 0x00,
                              0x01, 0x00, 0x00, 0x00};

    uc_engine* uc = nullptr;
    try {
        check(uc_open(UC_ARCH_X86, UC_MODE_64, &uc), "uc_open");

        for (auto [addr, size] : std::initializer_list<std::pair<uint64_t, uint64_t>>{
                 {kReturnAddr, kPageSize}, {kScratchBase, kScratchSize},
                 {kHeapBase, kHeapSize},   {kStackBase, kStackSize}}) {
            check(uc_mem_map(uc, addr, size, UC_PROT_ALL), "uc_mem_map region");
        }
        const uint8_t hlt = 0xF4;
        check(uc_mem_write(uc, kReturnAddr, &hlt, 1), "write HLT");

        std::printf("[a64] CoreFP        = %s\n", coreFPPath.c_str());
        std::printf("[a64] AirTrafficHost= %s\n", athPath.c_str());
        std::printf("[a64] 基址：CoreFP=%#llx  ATH=%#llx  相距=%llu MiB（MAX_IMG_SPAN=256 MiB）\n",
                    (unsigned long long)kCoreFPBase, (unsigned long long)kATHostBase,
                    (unsigned long long)((kATHostBase - kCoreFPBase) >> 20));

        // ── 1. 解析两个镜像（MachImage::Open 会自己切 x86-64 片）───────────────
        auto imgCoreFP = MachImage::Open("CoreFP", ReadFile(coreFPPath));
        auto imgATH    = MachImage::Open("AirTrafficHost", ReadFile(athPath));

        // ── 2. 收集 CoreFP 的全部导出，交给 SapShims 的 _dlsym 桩按名查 ────────
        //    这里**不写死 ATH 需要哪几个名字** —— 由 ATH 自己在运行时 dlsym 决定。
        std::unordered_map<std::string, uint64_t> coreFPExports;
        for (const char* n : kCoreFPExportNames) {
            try {
                coreFPExports[n] = imgCoreFP->Export(n, kCoreFPBase);
                std::printf("[a64] CoreFP 导出 %-20s = %#llx\n", n,
                            (unsigned long long)coreFPExports[n]);
            } catch (const std::exception& e) {
                std::printf("[a64] CoreFP 导出 %-20s 缺失（%s）\n", n, e.what());
            }
        }

        // ── 3. shims ───────────────────────────────────────────────────────────
        std::vector<uint8_t> icxs;
        if (!icxsPath.empty()) {
            icxs = ReadFile(icxsPath);
            std::printf("[a64] CoreFP.icxs  = %zu 字节\n", icxs.size());
        }
        auto shims = std::make_unique<SapShims>(uc, std::move(coreFPExports),
                                                std::move(icxs), std::vector<uint8_t>{});
        shims->SetHeap(kHeapBase, kHeapSize);

        auto resolver = [&](std::string_view name) -> uint64_t { return shims->Resolve(name); };

        // ── 4. Relocate + Load（两次都成功 ⇒ Unicorn 证明了两个区间不重叠）─────
        imgCoreFP->Relocate(kCoreFPBase, resolver);
        imgCoreFP->Load(uc);
        std::printf("[a64] CoreFP 已加载 @ %#llx\n", (unsigned long long)kCoreFPBase);

        imgATH->Relocate(kATHostBase, resolver);
        imgATH->Load(uc);
        std::printf("[a64] AirTrafficHost 已加载 @ %#llx（两次 uc_mem_map 都成功 ⇒ 区间不重叠）\n",
                    (unsigned long long)kATHostBase);

        // ── 5. 取 Grappa 生成函数（N_PEXT，必须走 ExportPrivate）──────────────
        const uint64_t fn = imgATH->ExportPrivate("_uhO2GULXwfgKwPcp4YR2", kATHostBase);
        std::printf("[a64] _uhO2GULXwfgKwPcp4YR2 = %#llx\n", (unsigned long long)fn);

        // ── 6. 备好 4 个参数（放在 scratch 里，便于出错时直接看内存）──────────
        const uint64_t inAddr  = kScratchBase;          // 12 字节输入
        const uint64_t sidAddr = kScratchBase + 0x20;   // int sessionId（in/out，初值 0）
        const uint64_t outAddr = kScratchBase + 0x30;   // void *outPtr
        const uint64_t lenAddr = kScratchBase + 0x38;   // uint32 outLen

        // ── 7. 连调两次 ────────────────────────────────────────────────────────
        // 为什么在**同一个 run 内**调两次、而不是跑两次 CI：
        //   要判的「两次输出是否相同」—— 相同 ⇒ 硬编码/常量填充的强信号。
        //   同进程连调两次，一次 CI 就能给出答案，还顺带排除了「两次 run 环境不同」
        //   这个混淆因素（堆布局、随机源种子、runner 差异）。
        std::printf("[a64] 调用 #1：f(in12, &sessionId=0, &outPtr, &outLen) …\n");
        const CallResult c1 = RunGrappaOnce(uc, *shims, fn, in12, inAddr, sidAddr, outAddr, lenAddr);
        std::printf("[a64]   err=%d outPtr=%#llx outLen=%u sessionId=%u\n",
                    c1.err, (unsigned long long)c1.outPtr, c1.outLen, c1.sid);

        std::printf("[a64] 调用 #2：同样入参再跑一次 …\n");
        const CallResult c2 = RunGrappaOnce(uc, *shims, fn, in12, inAddr, sidAddr, outAddr, lenAddr);
        std::printf("[a64]   err=%d outPtr=%#llx outLen=%u sessionId=%u\n",
                    c2.err, (unsigned long long)c2.outPtr, c2.outLen, c2.sid);

        // 注意：Invoke() 内部已按 SapMachine 的顺序检查过 HasFault()，
        // 有 fault 的话这里根本走不到 —— 它是以异常形式报出来的。

        // #1 是**主判据**：A-64 的核心问题（能不能生成 Grappa）由它回答。
        if (c1.err != 0) {
            std::printf("\n[a64] 结果：失败 —— err!=0（#1=%d，期望 0）\n", c1.err);
            return 1;
        }
        if (c1.outLen != 84) {
            std::printf("\n[a64] 结果：失败 —— outLen!=84（#1=%u，期望 84）\n", c1.outLen);
            return 1;
        }
        if (!c1.outPtr) {
            std::printf("\n[a64] 结果：失败 —— outPtr==NULL（#1：err/outLen 对了但没吐出缓冲区）\n");
            return 1;
        }

        // #2 只用于判「输出是否随机」。★ 它失败**不能**推翻 #1 的结论 ——
        // 这个函数可能就是一次性的（会话状态被 #1 消费掉），
        // 若把 #2 也当硬判据，就会凭空造出一个假失败，把已证明的结论推翻。
        const bool twoOk = (c2.err == 0 && c2.outLen == 84 && c2.outPtr != 0 && !c2.blob.empty());
        if (!twoOk) {
            std::printf("\n[a64] ⚠️ 调用 #2 未成功（err=%d outLen=%u outPtr=%#llx）"
                        " ⇒ 随机性未验，但**不影响 #1 的结论**\n",
                        c2.err, c2.outLen, (unsigned long long)c2.outPtr);
        }

        std::printf("\n[a64] Grappa #1（%u 字节）：\n", c1.outLen);
        HexDump(c1.blob);
        if (twoOk) {
            std::printf("\n[a64] Grappa #2（%u 字节）：\n", c2.outLen);
            HexDump(c2.blob);
        }

        if (AllZero(c1.blob, 0, c1.blob.size())) {
            std::printf("\n[a64] 结果：可疑 —— 内容全 0（#1）\n");
            return 1;
        }

        // ── 8. 已知结构核对（把「真 Grappa」与「空壳成功」分开）─────────────────
        std::printf("\n[a64] 已知结构核对（[0..1]=01 01 / [2..17] 16B / [18..19] u16LE 高 14 位 0x4000 / [20..83] 64B）：\n");
        const bool s1 = CheckStructure(c1.blob, "#1");
        const bool s2 = twoOk ? CheckStructure(c2.blob, "#2") : true;

        // ── 9. 两次比对（只在 #2 跑成时才有意义）────────────────────────────────
        size_t diff = 0, diffVar16 = 0, diffVar64 = 0;
        if (twoOk) {
            for (size_t i = 0; i < 84; ++i) {
                if (c1.blob[i] != c2.blob[i]) {
                    ++diff;
                    if (i >= 2 && i <= 17) ++diffVar16;
                    if (i >= 20)          ++diffVar64;
                }
            }
            std::printf("\n[a64] 两次比对：84 字节中 %zu 个不同"
                        "（16 字节段 %zu/16，64 字节段 %zu/64）\n", diff, diffVar16, diffVar64);
            std::printf("[a64]   [0..1]   #1=%02x %02x  #2=%02x %02x   %s\n",
                        unsigned(c1.blob[0]), unsigned(c1.blob[1]),
                        unsigned(c2.blob[0]), unsigned(c2.blob[1]),
                        (c1.blob[0] == c2.blob[0] && c1.blob[1] == c2.blob[1])
                            ? "一致（应为常量）✓" : "★ 不一致（常量都变了）");
            std::printf("[a64]   sessionId #1=%u  #2=%u   %s\n", c1.sid, c2.sid,
                        c1.sid == c2.sid ? "★ 两次相同（可疑）" : "不同 ✓");
        }

        if (!s1 || !s2) {
            std::printf("\n[a64] 结果：失败 —— 结构核对未通过（见上面 ✗ 行；err=0 但产出的不是已知布局）\n");
            return 1;
        }
        if (twoOk && diff == 0) {
            std::printf("\n[a64] 结果：失败 —— 两次完全相同（硬编码/常量填充的强信号）\n");
            return 1;
        }
        if (!twoOk) {
            std::printf("\n[a64] 结果：★ 通过（仅 #1）—— err=0, outLen=84, 结构符合已知布局；"
                        "#2 未跑成 ⇒ 随机性**未验**\n");
            return 0;
        }
        std::printf("\n[a64] 结果：★ 通过 —— err=0, outLen=84, 结构符合已知布局, 两次输出不同（%zu/84 字节）\n", diff);
        return 0;
    } catch (const std::exception& e) {
        std::printf("\n[a64] 异常：%s\n", e.what());
        if (uc) uc_close(uc);
        return 1;
    }
}
