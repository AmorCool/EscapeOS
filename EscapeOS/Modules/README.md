# EscapeOS/Modules —— 模块原生 UI 源码（**生成目录，不要手改**）

这个目录里的内容由 `Resources/Scripts/sync_bundled_modules.py` 从**模块仓库**
（`module-esc`）的 `modules/<id>/ui/` 拷贝而来。

## 为什么 UI 源码放在模块仓库，而不是这里

用户的意见：模块要**真正独立**，SwiftUI 界面应该集成在模块里，而不是散在宿主仓库。

而 SwiftUI 视图**必须编译**（设备上没有 Swift 编译器，zip 里放 .swift 也没有运行时作用），
所以采取折中：**源码归模块仓库所有**，CI 在 `xcodegen` 之前把它拷到这里，
宿主构建时自然带上。模块仓库是唯一数据源，宿主仓库不再持有副本。

## ⚠️ 本地开发

克隆后**必须**先跑一次（否则这里为空、`registerAirliftPocModuleUI` 找不到符号、编译失败）：

```bash
git clone --depth 1 https://github.com/AmorCool/module-esc.git _module-esc
python3 Resources/Scripts/sync_bundled_modules.py _module-esc
rm -rf _module-esc
```

## 代价

改 UI 仍需**重编宿主**（做不到热更新）。要热更新只能走模块的 `webroot`（HTML）那条路 ——
宿主的 `ModuleManagerView` 是「原生优先，没有再退回 webroot」。
