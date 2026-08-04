# LocalOps 30 轮真实行为回归

测试日期：2026-08-04

测试对象：v1.0.0 候选 release 构建（Apple Silicon arm64、ad-hoc 签名）。`v0.4.0` 是历史 Swift 基线。本轮结果没有外推为干净 macOS 13 或 Developer ID/notarized 结果。

证据标记：`自动` 表示本轮 XCTest/脚本真实执行；`审计` 表示只读检查源码或静态资源；`待人工` 表示需要在目标 Mac 上操作菜单栏、SwiftUI 窗口或浏览器。

## 结果

| 轮次 | 用户行为 | 本轮证据 |
|---:|---|:---:|
| 1 | 从构建产物首次启动 LocalOps | 待人工 blocker：当前 Mac 锁屏，不能宣称启动体验通过 |
| 2 | 打开菜单栏弹窗并读取服务、机器摘要和只读 Web 地址 | 待人工 blocker：菜单栏 popover 与原生窗口需解锁后复核 |
| 3 | 点击菜单栏“立即扫描”并观察数据刷新 | 待人工 blocker：菜单栏点击需解锁后复核；Engine/refresh 有自动覆盖 |
| 4 | 已运行时再次打开 App，确认没有重复进程 | 自动运行证据：仅保留原 PID；原生窗口复用仍需解锁后人工确认 |
| 5 | 浏览器打开只读首页 | 真实浏览器通过；URLSession XCTest 另有覆盖 |
| 6 | 查看已登记、健康、异常和待登记摘要 | 真实浏览器/API 通过；原生管理窗口仍为锁屏 blocker |
| 7 | 查看内存、磁盘、热状态、CPU Load 和开机时长 | 自动（系统指标 XCTest） |
| 8 | 查看已登记、待登记服务卡片和状态信息 | 人工通过服务页、编辑器和非法 file URL 校验；自动覆盖 API DTO |
| 9 | 筛选“已登记” | 真实浏览器通过（四档筛选之一） |
| 10 | 筛选“待登记” | 真实浏览器通过（四档筛选之一） |
| 11 | 筛选“最近掉线”并显示空状态 | 真实浏览器通过（四档筛选之一）；原生历史页待解锁 |
| 12 | 恢复“全部”筛选 | 真实浏览器通过（四档筛选之一） |
| 13 | 按服务名搜索 oMLX | 真实浏览器通过 |
| 14 | 按端口 8000 搜索 | 真实浏览器通过 |
| 15 | 搜索不存在的服务并显示空状态 | 真实浏览器通过 |
| 16 | 用键盘清空搜索并恢复全部卡片 | 真实浏览器通过；VoiceOver/键盘完整可访问性待解锁 |
| 17 | 检查服务入口链接、`_blank` 和 `noreferrer` | 审计（Web 资源）；浏览器点击待人工 |
| 18 | 1180px 桌面布局，无横向溢出 | 真实浏览器通过：`overflow=0` |
| 19 | 900px 中等窗口布局，无横向溢出 | 真实浏览器通过：`overflow=0` |
| 20 | 680px 窄窗口布局，无横向溢出 | 真实浏览器通过：`overflow=0` |
| 21 | 390px 手机宽度布局，无横向溢出 | 真实浏览器通过：`overflow=0` |
| 22 | 等待 15 秒，页面自动获取新 snapshot | 真实浏览器通过：自动重连/刷新保留上次结果 |
| 23 | 刷新页面，筛选和搜索恢复默认值 | 真实浏览器通过 |
| 24 | 检查浏览器 warning/error 日志 | 真实浏览器通过：0 warning、0 error |
| 25 | 读取 overview API 和完整机器指标 | 人工通过；自动（XCTest/API） |
| 26 | 读取服务详情，并验证未知服务返回 404 | 人工通过；审计/自动 GET 路由 |
| 27 | 检查 CSP、no-store、nosniff 和静态资源类型 | 审计（源码）；真实响应头待人工 |
| 28 | 对 API 发出 POST、PUT、PATCH、DELETE | 自动通过：全部 GET-only 路由矩阵返回 404，generation 不变 |
| 29 | 使用同一临时数据目录退出并重启，检查事件和登记项 | 自动运行证据：重复启动仅原 PID；数据/备份由 SQLite 测试覆盖 |
| 30 | 退出 App，确认 8042 端口释放 | 自动运行证据：正常退出后 0.212s 释放；8042 冲突时原生进程继续运行 |

## 本轮自动化证据

- `swift package clean && swift build -c release --product LocalOps`：通过；
- `swift test`：32/32 通过（10 项行为 + 22 项可靠性），0 failures、0 skipped；
- `LOCALOPS_FORBID_XCTSKIP=1 ./Scripts/ci-quality.sh`：通过；OSV 无漏洞、gitleaks 无泄漏、SPDX SBOM 和许可证清单生成；
- 可靠性覆盖：两次失败阈值/恢复事件去重、发现失败 stale 保留、projection age/ready、生产 64 KiB 响应边界与 JSON 脱敏、真实命令取消、首次 discovery 自愈、0700/0600 权限、30 天/10,000 条事件上限、stdout/stderr 背压/超时/输出上限、loopback/端口/PID/重定向/超大响应、启用端口冲突原子性、`/readyz` 503/200、重复端口冲突、停止后复用端口、SQLite 完整性/marker/备份/WAL/exclusive lock、legacy 事务 rollback、clear 目录数据语义、PID 复用/ambiguous 归属、ObservationEvidence 兼容/fingerprint/confidence、GET-only Web 路由不触发扫描且 recovery note 不出现在 API、ServiceDefinition URL 边界；
- 20 服务探测预算：每项健康检查延迟 100ms，生成 20 个 snapshot，总耗时约 0.365s（门禁 <5s），并发度观测在 2...8；
- `build-app.sh`：arm64、minOS 13.0、严格 ad-hoc codesign、dSYM 通过；
- `build-dmg.sh`：`hdiutil verify` 通过，SHA-256 sidecar 在 `release/` 目录内校验通过；重建后的候选 `LocalOps-1.0.0-arm64.dmg` SHA-256 为 `7c7d3ffc3524dad94feb420308c61439cd8649c5adebca5c1ecb3c3b647524a1`，App/dSYM UUID 均为 `30C27DCA-E4C8-3C46-9551-40A533D780B8`。
- 真实浏览器证据：1180/900/680/390 px 四档 `overflow=0`；搜索、四档筛选、断连保留/自动重连通过；控制台 0 warning、0 error。
- 最终打包后 Chrome forced-dark 1180×900 实图检查无溢出/截断；断连时显示 `state=stale`、标题“连接不可用”，保留 5 张卡片，age 由 27 秒增长至 1 分钟仍继续增长；自动重连清错。
- 当前 Mac 锁屏，菜单栏、原生窗口、VoiceOver、200% 字号、通知授权和断连重试按钮均明确列为人工 blocker，不得写成通过。

## 待人工发布门禁

1. 当前 Mac 解锁后复核菜单栏、原生窗口、VoiceOver 焦点、200% 字号、通知授权和断连重试按钮；这些 blocker 未完成前不能宣称 UI 通过。
2. 在干净 macOS 13 arm64 设备验证启动、安装、升级、回滚和 Gatekeeper 提示；当前开发机结果不能替代该证据。
3. 通过真实浏览器复核 CSP、缓存策略、控制台日志、GET-only 路由和 15 秒轮询（已有本轮 overflow/filter/reconnect 证据）。
4. 退出 App 后确认 8042 端口释放，再次启动确认数据和备份可恢复。
5. Developer ID/notarization 属于 post-v1 可选改善；当前免费 GitHub ad-hoc 分发按安装说明使用 Finder Control-click → 打开，`spctl` 被拒绝是预期结果。
