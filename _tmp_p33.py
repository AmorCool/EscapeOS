import io

def patch(path, old, new, count=1):
    s = io.open(path, encoding='utf-8').read().replace('\r\n', '\n')
    assert s.count(old) == count, (path, old[:60], s.count(old), s.count(old))
    io.open(path, 'w', encoding='utf-8', newline='\n').write(s.replace(old, new))

p = 'EscapeOS/Views/ProcessManagerView.swift'

# ① 解析用真实下标：physFootprint 在 74 属性列表中不在 0 位（0 = msgRecv 消息计数器！）
patch(p,
'''            // 6. 解析 processes dict → { "pid": [physFootprint_value] }''',
'''            // physFootprint 在属性数组中的真实下标（74 属性里它不在 0 位！
            // 之前写死 index 0 读到的是 msgRecv 消息计数器——这就是全是小数字的根因）
            guard let fpIdx = attrNames.firstIndex(of: "physFootprint") else {
                throw makeError("属性列表中无 physFootprint")
            }
            SysmonLogger.shared.log("[SysmonDiag] physFootprint 下标=\\(fpIdx)")

            // 6. 解析 processes dict → { "pid": [attr0, attr1, ...] }''')

patch(p,
'''                // val 是数组，第一个元素 = physFootprint
                guard let v = val else { continue }
                let item = plist_array_get_item(v, 0)
                guard let footprint = item, footprint != nil else { continue }
                var mem: UInt64 = 0
                plist_get_uint_val(footprint, &mem)
                if mem > 0 { result[pid] = mem }''',
'''                // val 是数组，physFootprint 位在 fpIdx
                guard let v = val else { continue }
                let item = plist_array_get_item(v, UInt32(fpIdx))
                guard let footprint = item, footprint != nil else { continue }
                var mem: UInt64 = 0
                plist_get_uint_val(footprint, &mem)
                if mem > 0 { result[pid] = mem }''')

# ② 导出分享：改用 ShareSheet(items: [logText])（与 LoginLogView 完全一致）
patch(p,
'''            .sheet(isPresented: $showShare) {
                if let url = shareURL {
                    ActivityShareView(url: url)
                }
            }''',
'''            .sheet(isPresented: $showShare) {
                ShareSheet(items: [logText])
            }''')

print('①② 修复完成')
