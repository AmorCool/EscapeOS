//go:build windows

package unicorn

// v0.3.11：Windows（GOOS=windows 交叉编译，EscapeSapServer.exe）下的引擎配置。
// 与非 Windows 平台一致：静态 cgo 链接无需额外引擎配置，直接返回 nil。
// 此文件缺失导致 GOOS=windows 时 configureEngine 未定义（engine_config_default.go
// 标了 //go:build !windows）——cmd/server 首次 Windows 构建实锤。
func configureEngine(*Engine) error {
	return nil
}
