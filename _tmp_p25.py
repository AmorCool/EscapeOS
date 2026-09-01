import io

def patch(path, old, new, count=1):
    s = io.open(path, encoding='utf-8').read().replace('\r\n', '\n')
    assert s.count(old) == count, (path, old[:60], s.count(old), s.count(old))
    io.open(path, 'w', encoding='utf-8', newline='\n').write(s.replace(old, new))

p = 'EscapeOS/Views/RootView.swift'

# NavigationView → NavigationStack（3 处 tab 根）
patch(p, '            NavigationView {\n                appsContent', '            NavigationStack {\n                appsContent')
patch(p, '            NavigationView {\n                SpaceReclaimView', '            NavigationStack {\n                SpaceReclaimView')
patch(p, '            NavigationView {\n                MoreView(appList: viewModel', '            NavigationStack {\n                MoreView(appList: viewModel')

print('RootView NavigationStack 完成')

# fetchMemoryUsage：查询系统属性 + interval_ms=1（ur=1 对齐 pmd3）
p2 = 'EscapeOS/Views/ProcessManagerView.swift'

patch(p2,
'''            var config = IdeviceSysmontapConfig(
                interval_ms: 1,
                process_attributes: attrPtrs,
                process_attributes_count: UInt(attrNames.count),
                system_attributes: nil,
                system_attributes_count: 0
            )''',
'''            // 查询系统属性列表（空 sysAttrs 会导致设备断连——pmd3 传完整列表）
            var sysAttrs: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>? = nil
            var sysAttrCount: Int = 0
            var sysAttrNames: [String] = []
            if let err = device_info_sysmon_system_attributes(devInfo, &sysAttrs, &sysAttrCount) {
                SysmonLogger.shared.log("[SysmonDiag] step3c 系统属性查询失败（继续用空列表）: \\(error(from: err, fallback: "?").localizedDescription)")
            } else if let sysAttrs, sysAttrCount > 0 {
                for i in 0..<sysAttrCount {
                    if let ptr = sysAttrs[i] {
                        sysAttrNames.append(String(cString: ptr))
                    }
                }
                device_info_string_array_free(sysAttrs, UInt(sysAttrCount))
                SysmonLogger.shared.log("[SysmonDiag] step3c 系统属性(\\(sysAttrCount)): \\(sysAttrNames.prefix(5).joined(separator: ","))…")
            }

            var sysCAttrs: [UnsafeMutablePointer<CChar>] = []
            for name in sysAttrNames {
                if let buf = strdup(name) { sysCAttrs.append(buf) }
            }
            defer { for buf in sysCAttrs { free(UnsafeMutableRawPointer(buf)) } }
            var sysPtrs: [UnsafePointer<CChar>?] = sysCAttrs.map { UnsafePointer($0) }
            sysPtrs.append(nil)

            // ur=1 对齐 pymobiledevice3（interval_ms 同时写 ur 和 sampleInterval）
            var config = IdeviceSysmontapConfig(
                interval_ms: 1,
                process_attributes: attrPtrs,
                process_attributes_count: UInt(attrNames.count),
                system_attributes: sysPtrs,
                system_attributes_count: UInt(sysAttrNames.count)
            )''')

print('sysmontap 系统属性补丁完成')
