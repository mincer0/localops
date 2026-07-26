# LocalOps 实施计划

更新日期：2026-07-26

## v0.4.0：纯 Swift 基线

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
- [x] 旧 LocalOps LaunchAgent 安全清理；
- [x] 纯 Swift 自动化测试运行器；
- [x] `.app` 和 DMG 构建脚本。

验收标准：

```text
swift build                 通过
swift run LocalOpsTests     通过
Scripts/build-app.sh        通过
codesign --verify --deep    通过
127.0.0.1:8042              只有 GET 信息路由
退出 App                  8042 停止监听
Python/FastAPI              不在跟踪源码中
```

## v0.4.x：只读产品化

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
