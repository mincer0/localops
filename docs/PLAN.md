# LocalOps 实施计划

更新日期：2026-08-04

## v1.0.0：本地发布候选

当前目标是生成 v1.0.0 本地发布候选，不自动创建 Release、不推送 tag。候选沿用 v0.4.0 的纯 Swift 基线，并将可靠性、严格质量门禁、只读 Web readiness、原生设置/诊断和候选打包纳入验收。

- [x] 32 项 XCTest 真实断言（10 behavior + 22 reliability），tag 候选 0 skipped（含 projection、取消、WAL/SQLite、清除语义、观察归属、Web readiness/privacy 和 URL 边界）；
- [x] strict Swift format、锁文件、OSV、gitleaks、许可证清单和 SPDX SBOM；
- [x] arm64/minOS 13.0、codesign、dSYM、DMG 校验和候选脚本；
- [ ] 干净 macOS 13 arm64 设备、通知授权、最新候选菜单 popover/原生 UI 和 GitHub workflow 实际绿；Developer ID/notarization 属于 post-v1 可选改善。

## v0.4.0：历史纯 Swift 基线

目标：删除 Python/FastAPI 产品运行链路，在一个 macOS App 中完成发现、健康、历史、原生 UI 和只读 Web。

- [x] SwiftPM 目标分层；
- [x] GRDB / SQLite schema 与旧数据库兼容；
- [x] `DefaultServices.json`；
- [x] 旧 YAML 一次性迁移；
- [x] `lsof` 发现和稳定历史 id；
- [x] HTTP / TCP / PID 健康检查；
- [x] 热状态、CPU Load、内存、磁盘和开机时长；
- [x] SwiftUI 菜单栏和管理窗口；
- [x] 原生登记与忘记发现服务；
- [x] FlyingFox 只读页面和 GET API；
- [x] 不自动控制或删除旧 LaunchAgent；如用户确认存在遗留项，按安装/迁移说明手动处理；
- [x] 纯 Swift 自动化测试运行器；
- [x] `.app` 和 DMG 构建脚本。

验收标准：

```text
swift build                 通过
swift test                  通过（10 项行为 + 22 项可靠性真实断言，tag 禁止 skip）
Scripts/build-app.sh        通过
codesign --verify --deep    通过
127.0.0.1:8042              只有 GET 信息路由
退出 App                  8042 停止监听
Python/FastAPI              不在跟踪源码中
```

## v0.4.x：历史只读产品化记录

1. 补齐原生服务编辑界面，包括 HTTP 路径、TCP 端口和超时；
2. 增加通知规则，仅对已登记服务的持续异常发送通知；
3. 为事件增加保留期和上限；
4. 增加无障碍、深色模式与窄窗口回归；
5. 完成 DMG 真实升级验证。

## 后续：服务启停

当产品需求确定后，再在下列方式中做取舍：

- 服务官方 CLI；
- LocalOps 生成的用户级 launchd 托管；
- macOS App / `NSWorkspace`；
- Apple Container 或 Docker 类容器；
- 仅观察。

在此之前，不在 schema 和 UI 中加入未确定的启停字段，也不开放任意 shell。
