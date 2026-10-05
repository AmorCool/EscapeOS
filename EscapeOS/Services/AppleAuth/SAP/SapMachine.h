#pragma once
#include "MachImage.h"

#include <cstdint>
#include <functional>
#include <memory>
#include <string>
#include <string_view>
#include <unordered_map>
#include <vector>
#include <stdexcept>
#include <span>

struct uc_struct;
typedef struct uc_struct uc_engine;
typedef size_t uc_hook;

// ─────────────────────────────────────────────────────────────────────────────
//  SapShims
//
//  Host-side service layer injected into the emulated Apple dylibs.
//  Intercepts all external symbol imports (malloc, pthread, etc.) via a
//  Unicorn code hook over the shim code area, handles them natively, and
//  returns results through the x86-64 SysV ABI (RAX).
//
//  Memory layout (all in the [shimBase, shimBase+shimSize) range):
//    [shimBase            .. shimBase+shimCodeSize)  — RET stubs (one per shim)
//    [shimBase+shimCodeSize .. shimBase+shimSize)    — static guest data
// ─────────────────────────────────────────────────────────────────────────────
class SapShims {
public:
    static constexpr uint64_t kShimBase     = 0x0000200000000000ULL;
    static constexpr uint64_t kShimCodeSize = 0x0000000000080000ULL; // 512 KB
    static constexpr uint64_t kShimSize     = 0x0000000000100000ULL; // 1 MB
    static constexpr uint64_t kSlotSize     = 16;

    // ctor: pass the engine, CoreFP export map, CoreFP.icxs blob.
    SapShims(uc_engine* uc,
             std::unordered_map<std::string, uint64_t> coreFPExports,
             std::vector<uint8_t> icxs,
             std::vector<uint8_t> macAddress = {});
    ~SapShims();

    // Resolve an import name to a shim stub address (or CoreFP real address).
    // Unknown imports fault when invoked, rather than silently succeeding.
    uint64_t Resolve(std::string_view name);

    // True if the last invocation set a fault.
    bool HasFault() const { return !fault_.empty(); }
    std::string TakeFault() { auto f = fault_; fault_.clear(); return f; }
    void        ResetFault() { fault_.clear(); }

    // Called by the machine before each guest function invocation.
    void BeforeInvoke() { ResetFault(); }

private:
    // ── shim registration ─────────────────────────────────────────────────────
    using Handler = std::function<void()>;

    uint64_t AddFunction(std::string name, Handler handler);
    uint64_t AddData(std::string name, const void* data, size_t len);
    void     AddAliases(std::initializer_list<const char*> names, Handler h);

    void RegisterMemoryServices();
    void RegisterPlatformServices();

    // ── Unicorn code hook dispatch ─────────────────────────────────────────────
    static void HookCallback(uc_engine*, uint64_t addr, uint32_t, void* user);
    void        Dispatch(uint64_t addr);
    void        Fail(std::string msg);

    // ── ABI helpers ───────────────────────────────────────────────────────────
    uint64_t Arg(int index);               // read argument (reg or stack)
    void     SetResult(uint64_t value);    // write RAX
    void     ReturnZero() { SetResult(0); }

    // ── Guest memory helpers ───────────────────────────────────────────────────
    uint32_t GuestRead32(uint64_t addr);
    uint64_t GuestRead64(uint64_t addr);
    void     GuestWrite32(uint64_t addr, uint32_t v);
    void     GuestWrite64(uint64_t addr, uint64_t v);
    void     GuestRead(uint64_t addr, void* dst, size_t len);
    void     GuestWrite(uint64_t addr, const void* src, size_t len);
    std::string GuestReadCString(uint64_t addr);

    // ── Guest heap (within Unicorn heapBase region, managed by machine) ────────
    // The machine passes a heap helper that SapShims calls.
    // For simplicity we keep a shadow allocator in host memory that mirrors
    // what we write into the emulated heap region.
    struct Alloc { uint64_t guestAddr; size_t size; };

public:
    // Called by SapMachine to give us access to the heap region.
    void SetHeap(uint64_t heapBase, uint64_t heapSize);

private:
    uint64_t HeapAlloc(uint64_t size);
    void     HeapFree(uint64_t guestPtr);
    uint64_t HeapRealloc(uint64_t oldPtr, uint64_t newSize);

    // ── state ─────────────────────────────────────────────────────────────────
    uc_engine* uc_      = nullptr;
    uc_hook    hook_    = 0;

    std::unordered_map<std::string, uint64_t> coreExports_;
    std::vector<uint8_t>                      icxs_;
    std::vector<uint8_t>                      macAddress_; // actual machine MAC for _get_mac_address shim
    size_t                                    icxsOffset_ = 0;

    uint64_t codeCursor_ = kShimBase;
    uint64_t dataCursor_ = kShimBase + kShimCodeSize;

    std::unordered_map<uint64_t, std::pair<std::string, Handler>> entries_; // addr→(name,handler)
    std::unordered_map<std::string, uint64_t>                     symbols_; // name→addr

    // errno cell (guest pointer to a uint32)
    uint64_t errnoCell_ = 0;

    // Heap
    uint64_t heapBase_   = 0;
    uint64_t heapEnd_    = 0;
    uint64_t heapSize_   = 0;
    uint64_t heapCursor_ = 0;

    struct FreeBlock  { uint64_t addr; uint64_t size; };
    struct GuestAlloc { uint64_t size; uint64_t reserved; };

    std::vector<FreeBlock>                           freeBlocks_;
    std::unordered_map<uint64_t, GuestAlloc>         allocations_; // guestPtr→{size,reserved}
    void CoalesceFreeBlocks();

    // Fake file descriptor for CoreFP.icxs
    static constexpr int kIcxsFd = 100;
    [[maybe_unused]] bool icxsFdOpen_ = false;

    // pthread_once / dispatch_once simulation
    std::unordered_map<uint64_t, bool> onceTokens_;

    // Misc iteration counter (CoreFP internal)
    uint32_t iterator_ = 0;

    std::string fault_;
};


// ─────────────────────────────────────────────────────────────────────────────
//  SapMachine
//
//  Complete emulated runtime for Apple's SAP (Secure Action Protocol).
//  Loads CoreFP + CommerceCore + CommerceKit into Unicorn x86-64, wires the
//  shim layer, and exposes the four SAP operations.
//
//  Typical usage:
//      auto m = SapMachine::Create(coreFP, commerceCore, commerceKit, icxs);
//      uint64_t ctx = m->Initialize(hardwareID);
//      auto [req, state] = m->Exchange(version, hardwareID, ctx, cert);
//      // state must be 1 after first exchange, 0 after second
//      auto [_, state2] = m->Exchange(version, hardwareID, ctx, serverReply);
//      auto sig = m->Sign(ctx, requestBody);
//      m->Teardown(ctx);
// ─────────────────────────────────────────────────────────────────────────────
class SapMachine {
public:
    static std::unique_ptr<SapMachine> Create(
        std::vector<uint8_t> coreFP,
        std::vector<uint8_t> commerceCore,
        std::vector<uint8_t> commerceKit,
        std::vector<uint8_t> coreFPIcxs,
        std::vector<uint8_t> hardwareID = {}); // used for _get_mac_address shim

    /// 有 StoreAgent 镜像时加载它并返回一个新的 SapMachine。
    ///
    /// 上游 ipatool 的 `openRuntime(ctx, bundle, runtimeOptions{extraImages: [...]})`
    /// 就是「在 CoreFP/CommerceCore/CommerceKit 之外**再挂一个镜像**」。
    /// `storeagent` 是独立可执行 Mach-O（不是 dylib），基址 `0x00001000C0000000`，
    /// 由 `ent/download` 的包解密链使用（见 `SapStoreAgent`）。
    ///
    /// - Parameter storeAgent: `CommerceKit.framework/.../Resources/storeagent`
    /// - Returns: 新实例；镜像解析/重定位失败抛 `std::runtime_error`。
    static std::unique_ptr<SapMachine> CreateWithStoreAgent(
        std::vector<uint8_t> coreFP,
        std::vector<uint8_t> commerceCore,
        std::vector<uint8_t> commerceKit,
        std::vector<uint8_t> coreFPIcxs,
        std::vector<uint8_t> storeAgent,
        std::vector<uint8_t> hardwareID = {});

    ~SapMachine();

    // SAP protocol operations — match the Go Machine API exactly.
    uint64_t              Initialize(std::span<const uint8_t> hardwareID);
    std::pair<std::vector<uint8_t>, int32_t>
                          Exchange(uint32_t version,
                                   std::span<const uint8_t> hardwareID,
                                   uint64_t ctx,
                                   std::span<const uint8_t> input);
    std::vector<uint8_t>  Sign(uint64_t ctx, std::span<const uint8_t> input);
    void                  Teardown(uint64_t ctx);

    // ── StoreAgent（`ent/download` 的包解密器）────────────────────────────────
    //
    // 对齐上游 ipatool `internal/sap/machine/storeagent.go`。三段式：
    //   global(0x0c5fc0) → session(0x0debd0) → decrypt(0x0ee700)  ← 偏移相对 kStoreAgentBase
    //
    // 用法：
    //     auto agent = machine->OpenStoreAgent(hardwareID, dpInfo);
    //     agent->Decrypt(ctx, dst, src);   // 流式，按 0x8000 分块
    //     agent->Close();
    //
    // 注意： 必须先经 `CreateWithStoreAgent(...)` 创建机器，否则三个入口都是 0。

    /// StoreAgent 会话。持有机器引用，**机器必须先于它存活**。
    class StoreAgent {
    public:
        /// 初始化全局上下文 + 会话。
        /// - Parameter dpInfo: 下载响应里 `sinfs[].dpInfo`（缺失或为空会直接报错，
        ///   上游明确 `if len(dpInfo) == 0 { return error }`）。
        static std::unique_ptr<StoreAgent> Open(SapMachine& machine,
                                                std::span<const uint8_t> hardwareID,
                                                std::span<const uint8_t> dpInfo);

        ~StoreAgent();

        /// 解密一段（≤ `kChunkSize`）。返回解密后的字节数。
        size_t DecryptChunk(std::span<uint8_t> buffer);

        /// 关会话（幂等）。
        void Close();

        /// 上游分块大小 `storeAgentChunkSize = 0x8000`。
        static constexpr size_t kChunkSize = 0x8000;

    private:
        StoreAgent(SapMachine& machine, uint64_t session, uint64_t decryptEntry, uint64_t closeEntry)
            : machine_(machine), session_(session), decryptEntry_(decryptEntry), closeEntry_(closeEntry) {}

        SapMachine& machine_;
        uint64_t    session_;
        uint64_t    decryptEntry_;
        uint64_t    closeEntry_;
        bool        closed_ = false;
    };

    /// 打开 StoreAgent 会话。见 `StoreAgent` 用法。
    std::unique_ptr<StoreAgent> OpenStoreAgent(std::span<const uint8_t> hardwareID,
                                               std::span<const uint8_t> dpInfo);

    // ── StoreAgent：kbsync 生成（`ent/download` 的请求凭据）──────────────────
    //
    // 对齐上游 ipatool `internal/sap/machine/kbsync.go` 的 `GenerateKBSync`。
    //
    // 注意： **和 `StoreAgent::Open` 不是一回事**：kbsync **不开会话**（不需要 dpInfo），
    // 只要全局上下文 + DSID 就能算出来。上游注释原话：
    //   > creates the account and hardware bound FairPlay data required by the bag's
    //   > ent/download endpoint, **without opening a decryption session**.
    // 所以它是**独立的一次 guest 调用**，调用完立刻关掉全局上下文。
    //
    // 上游 guest 调用签名（`kbsync.go:56`）：
    //     invoke(storeAgentKBSyncEntry, globalContext, dsid, 0, 1, pointerField, lengthField)
    // 输出走与 SAP 同一套 `consumeOutput`（pointerField 指向缓冲区、lengthField 是
    // uint32 长度但占 8 字节，高 4 字节为 0）。
    //
    /// 生成 kbsync 凭据。**必须先经 `CreateWithStoreAgent(...)` 建机器。**
    /// - Parameter dsid: 账号的 DirectoryServicesIdentifier，**必须非 0**（上游硬门）。
    /// - Returns: 供 `ent/download` 请求体 `kbsync` 字段使用的字节串。
    /// - Throws: 入口未解析、DSID 为 0、guest 返回非 0、输出为空。
    std::vector<uint8_t> GenerateKBSync(std::span<const uint8_t> hardwareID, uint64_t dsid);

private:
    SapMachine() = default;

    /// `Create` / `CreateWithStoreAgent` 的公共实现。
    /// `storeAgent` 为空 ⇒ 与旧 `Create` 行为完全一致（不挂额外镜像）。
    static std::unique_ptr<SapMachine> Build(
        std::vector<uint8_t> coreFP,
        std::vector<uint8_t> commerceCore,
        std::vector<uint8_t> commerceKit,
        std::vector<uint8_t> coreFPIcxs,
        std::vector<uint8_t> storeAgent,
        std::vector<uint8_t> hardwareID);

    // ── guest address space ───────────────────────────────────────────────────
    static constexpr uint64_t kReturnAddr  = 0x0000000100000000ULL;
    static constexpr uint64_t kCoreFPBase  = 0x0000100000000000ULL;
    static constexpr uint64_t kCommerceBase= 0x0000100040000000ULL;
    static constexpr uint64_t kKitBase     = 0x0000100080000000ULL;
    /// `storeagent` 镜像基址 —— 对齐上游 `storeAgentBase`（machine/storeagent.go:14）。
    static constexpr uint64_t kStoreAgentBase = 0x00001000C0000000ULL;
    // `storeagent` 的入口（偏移取自上游常量，逐字对应）：
    //   storeAgentGlobalInit   = storeAgentBase + 0x0c5fc0
    //   storeAgentKBSyncEntry  = storeAgentBase + 0x0c93c0
    //   storeAgentSessionInit  = storeAgentBase + 0x0debd0
    //   storeAgentDecryptEntry = storeAgentBase + 0x0ee700
    //   storeAgentSessionClose = storeAgentBase + 0x1212d0
    static constexpr uint64_t kStoreAgentGlobalInit   = kStoreAgentBase + 0x0c5fc0ULL;
    /// kbsync 生成入口 —— 上游 `storeAgentKBSyncEntry`（machine/storeagent.go:16）。
    /// `GenerateKBSync` 用它，**不经过 session**。
    static constexpr uint64_t kStoreAgentKBSyncEntry  = kStoreAgentBase + 0x0c93c0ULL;
    static constexpr uint64_t kStoreAgentSessionInit  = kStoreAgentBase + 0x0debd0ULL;
    static constexpr uint64_t kStoreAgentDecryptEntry = kStoreAgentBase + 0x0ee700ULL;
    static constexpr uint64_t kStoreAgentSessionClose = kStoreAgentBase + 0x1212d0ULL;
    /// `/Users/Shared/SC Info` —— 上游 `storeAgentSCInfoPath`，作为 global init 的路径参数。
    static constexpr const char* kStoreAgentSCInfoPath = "/Users/Shared/SC Info";
    static constexpr uint64_t kScratchBase = 0x0000300000000000ULL;
    static constexpr uint64_t kScratchSize = uint64_t(32) << 20; // 32 MB
    static constexpr uint64_t kHeapBase    = 0x0000400000000000ULL;
    static constexpr uint64_t kHeapSize    = uint64_t(64) << 20; // 64 MB
    static constexpr uint64_t kStackBase   = 0x0000500000000000ULL;
    static constexpr uint64_t kStackSize   = uint64_t(8)  << 20; //  8 MB
    static constexpr uint64_t kStackEnd    = kStackBase + kStackSize;
    static constexpr uint64_t kPageSize    = 0x1000;

    // ── SAP CommerceKit entry points ──────────────────────────────────────────
    struct EntryPoints {
        uint64_t initialize = 0; // _cp2g1b9ro
        uint64_t exchange   = 0; // _Mib5yocT
        uint64_t sign       = 0; // _Fc3vhtJDvr
        uint64_t teardown   = 0; // _IPaI1oem5iL
        uint64_t dispose    = 0; // _jEHf8Xzsv8K
    } entry_;

    // ── invoke helpers ────────────────────────────────────────────────────────
    static constexpr uint64_t kTimeout = 60'000; // ms, matches Go sapGuestTimeout

    // Invoke guest function with up to 8 args; returns RAX.
    uint64_t Invoke(uint64_t fn, std::initializer_list<uint64_t> args);

    // Scratch space (reset before each top-level call)
    uint64_t scratchCursor_ = 0;
    void     BeginCall()  { scratchCursor_ = 0; }

    // Allocate len bytes in scratch, optionally pre-fill with data.
    // Returns guest address.
    uint64_t Scratch(const void* data, uint64_t len);
    uint64_t Scratch(uint64_t len) { return Scratch(nullptr, len); }
    void     ClearScratch() noexcept;
    struct ScratchCleanup {
        SapMachine& machine;
        ~ScratchCleanup() { machine.ClearScratch(); }
    };

    // Read len bytes from guest memory into a host vector.
    std::vector<uint8_t> ConsumeOutput(uint64_t ptrField, uint64_t lenField);
    void Dispose(uint64_t guestPtr);

    // Helper: build a 24-byte hardwareBlock from 1-20 byte hardwareID.
    static std::vector<uint8_t> HardwareBlock(std::span<const uint8_t> id);

    uint64_t GuestRead64(uint64_t addr);
    uint32_t GuestRead32(uint64_t addr);
    void     GuestWrite(uint64_t addr, const void* src, size_t len);
    void     GuestWriteU8(uint64_t addr, uint8_t v);

    // ── state ─────────────────────────────────────────────────────────────────
    uc_engine*               uc_     = nullptr;
    std::unique_ptr<SapShims> shims_;
};
