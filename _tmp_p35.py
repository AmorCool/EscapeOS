import io

def patch(path, old, new, count=1):
    s = io.open(path, encoding='utf-8').read().replace('\r\n', '\n')
    assert s.count(old) == count, (path, old[:60], s.count(old), s.count(old))
    io.open(path, 'w', encoding='utf-8', newline='\n').write(s.replace(old, new))

p = 'EscapeOS/Views/ProcessManagerView.swift'

# ① ViewModel 加排序枚举 + sortedProcesses
patch(p,
'''final class ProcessManagerViewModel: ObservableObject {
    @Published private(set) var processes: [ProcessEntry] = []''',
'''/// 进程列表排序模式
enum ProcessSortMode: String, CaseIterable, Identifiable {
    case defaultOrder = "默认"
    case byName = "按名称"
    case byMemory = "按内存"
    var id: String { rawValue }
}

final class ProcessManagerViewModel: ObservableObject {
    @Published private(set) var processes: [ProcessEntry] = []
    /// v0.3.47：排序模式
    @Published var sortMode: ProcessSortMode = .defaultOrder''')

# ② sortedProcesses 计算属性（挂在 filteredProcesses 后）
patch(p,
'''    var filteredProcesses: [ProcessEntry] {
        guard !query.isEmpty else { return processes }
        return processes.filter {''',
'''    /// v0.3.47：排序后的进程列表（在搜索过滤基础上）
    var sortedProcesses: [ProcessEntry] {
        switch sortMode {
        case .defaultOrder:
            return filteredProcesses
        case .byName:
            return filteredProcesses.sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
        case .byMemory:
            // 未上报内存（nil）排最后；其余按占用从大到小
            return filteredProcesses.sorted {
                ($0.memoryBytes ?? -1) > ($1.memoryBytes ?? -1)
            }
        }
    }

    var filteredProcesses: [ProcessEntry] {
        guard !query.isEmpty else { return processes }
        return processes.filter {''')

print('①② ViewModel 排序完成')
