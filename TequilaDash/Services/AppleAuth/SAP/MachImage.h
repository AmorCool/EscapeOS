#pragma once
#include <cstdint>
#include <functional>
#include <memory>
#include <string>
#include <string_view>
#include <unordered_map>
#include <vector>
#include <stdexcept>

// unicorn/unicorn.h forward — include the real header before this in .cpp
struct uc_struct;
typedef struct uc_struct uc_engine;

// ─────────────────────────────────────────────────────────────────────────────
//  MachImage
//
//  Parses a Mach-O (or fat/universal) dylib, applies dyld-style rebases and
//  binds in-place, then loads the result into a Unicorn Engine instance.
//
//  Port of ipatool internal/sap/machimage, adapted for C++20 on Darwin.
//
//  Usage:
//      auto img = MachImage::Open("CoreFP", raw_bytes);
//      img->Relocate(coreFPBase, [&](std::string_view sym) {
//          return shims.resolve(sym);   // returns load address or throws
//      });
//      img->Load(uc);
//      uint64_t signAddr = img->Export("_Fc3vhtJDvr", coreFPBase);
// ─────────────────────────────────────────────────────────────────────────────
class MachImage {
public:
    // Open a Mach-O or fat universal binary.
    // Extracts the x86-64 slice; throws std::runtime_error on any format error.
    static std::unique_ptr<MachImage> Open(std::string name, std::vector<uint8_t> data);

    // Return the emulator address of an exported symbol when loaded at loadBase.
    // Throws std::runtime_error if the symbol is not found.
    uint64_t Export(std::string_view symbol, uint64_t loadBase) const;

    // 同上，但**额外**允许 `N_PEXT`（private external）符号。
    //
    // 为什么需要单独一个方法、而不是放宽 Export()：
    //   · Apple 会把内部实现标成 N_PEXT（`n_type = 0x1e = N_PEXT|N_SECT`，`N_EXT = 0`）。
    //     这类符号**不在 export trie 里**（trie 只收对外导出的名字），
    //     所以 Export() 的 symtab 回退路径是它们唯一的来源；
    //     而那条回退路径在 `ParseSymtab` 里按 `N_EXT` 过滤，把它们全丢了。
    //   · 例：macOS 的 AirTrafficHost 里 `_uhO2GULXwfgKwPcp4YR2`（Grappa 生成函数）
    //     就是 0x1e —— 实测该文件 export trie 58 项恰好等于公开符号 58 项，
    //     即它确实不在 trie 里。
    //   · 但 SAP 生产路径（CoreFP 的 6 个名字）用的是**公开导出**，
    //     放宽 Export() 会平白改变它的行为。所以这里**只加新方法，不动 Export()**。
    //
    // 实现是**直接遍历 LC_SYMTAB**（不依赖 exports_ 映射），
    // 因此与 `Export()` 的解析结果互不影响，也不会给 exports_ 引入新条目。
    uint64_t ExportPrivate(std::string_view symbol, uint64_t loadBase) const;

    // Apply dyld rebases and external bindings to the data buffer in-place.
    // resolve(symbolName) must return the emulator load address of that symbol,
    // or throw std::runtime_error("…") if unknown.
    // Must be called exactly once, before Load().
    void Relocate(uint64_t loadBase,
                  std::function<uint64_t(std::string_view)> resolve);

    // Map and write all loadable segments into Unicorn memory.
    // Relocate() must have been called first.
    void Load(uc_engine* uc) const;

    const std::string& Name() const { return name_; }

private:
    // ── internal segment record ───────────────────────────────────────────────
    struct Segment {
        std::string name;
        uint64_t    vmAddr   = 0;
        uint64_t    vmSize   = 0;
        uint64_t    fileOff  = 0;
        uint64_t    fileSize = 0;
    };

    // ── pending fixups (filled during parse, applied during Relocate) ─────────
    struct Rebase {
        std::string segment;   // target segment name
        uint64_t    offset;    // byte offset from segment start
        uint64_t    origValue; // original pointer value read from data[]
    };

    struct Bind {
        std::string segment;
        uint64_t    segOffset;
        std::string symbolName;
        int64_t     addend;
    };

    // ── private constructors / helpers ────────────────────────────────────────
    MachImage() = default;

    // Slice a fat binary down to its x86-64 Mach-O.
    static std::vector<uint8_t> ExtractAmd64Slice(const std::vector<uint8_t>& fat);

    // Parse load commands from data_ and fill all internal tables.
    void ParseLoadCommands();

    // Rebase/bind opcode stream interpreters.
    void ParseRebaseOpcodes(const uint8_t* start, size_t len);
    void ParseBindOpcodes(const uint8_t* start, size_t len, bool isLazy = false);

    // Export trie walk — fills exports_.
    void ParseExportTrie(const uint8_t* trie, size_t len);
    void WalkTrie(const uint8_t* trie, size_t len,
                  size_t node, std::string& prefix, size_t depth = 0);

    // Symbol table fallback — fills exports_ for any symbols not in trie.
    void ParseSymtab(const uint8_t* syms, uint32_t nsyms,
                     const char*   strtab, uint32_t strsize);

    // Translate (segmentName, offsetInSegment) → file offset in data_.
    uint64_t SegmentFileOffset(std::string_view segName,
                                uint64_t offset, uint64_t size) const;

    // Write an 8-byte little-endian pointer at a file offset in data_.
    void PutPointer(uint64_t fileOffset, uint64_t value);

    // Read an 8-byte little-endian pointer from a file offset in data_.
    uint64_t ReadPointer(uint64_t fileOffset) const;

    // ── state ─────────────────────────────────────────────────────────────────
    std::string              name_;
    std::vector<uint8_t>     data_;   // mutable x86-64 slice; modified by Relocate

    uint64_t                 imageBase_ = 0;    // preferred load address (from __TEXT)
    std::vector<Segment>     segments_;
    std::vector<Rebase>      rebases_;
    std::vector<Bind>        binds_;
    std::unordered_map<std::string, uint64_t> exports_; // symbol → vmAddr (in-image)

    // LC_SYMTAB 的原始位置（**存偏移而不是裸指针**）。
    // ExportPrivate() 要重新遍历一遍符号表，所以解析结果必须留到 ParseLoadCommands 之后；
    // 存偏移而非 data_.data()+off 的裸指针，是为了不依赖 data_ 的缓冲区地址稳定
    // （Relocate() 会原地改 data_，虽然不会重分配，但依赖这一点太脆）。
    uint32_t symtabSymsOff_  = 0;
    uint32_t symtabNsyms_    = 0;
    uint32_t symtabStrOff_   = 0;
    uint32_t symtabStrSize_  = 0;

    bool     relocated_   = false;
    uint64_t loadedBase_  = 0;
};
