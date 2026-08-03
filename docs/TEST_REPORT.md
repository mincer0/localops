# LocalOps v1.0.0 本地发布候选测试报告

`v0.4.0` 仅作为历史 Swift 迁移基线保留；本报告记录 v1.0.0 候选。

测试日期：2026-08-04

## 自动化覆盖

`swift test` 当前覆盖 10 项行为测试和 22 项可靠性测试（共 32 项）。可靠性测试全部执行真实断言，不使用 `XCTSkip`：

1. 默认 JSON 服务的校验和唯一 id；
2. IPv4、IPv6 和 wildcard 监听地址解析；
3. 历史服务 id 不依赖 PID；
4. 旧 YAML 服务的纯 Swift 迁移；
5. GRDB schema、服务定义、事件和发现历史持久化；
6. 内存、磁盘、CPU Load、逻辑核心、开机时长和热状态采集；
7. Engine 合并已登记、待登记和最近掉线服务；
8. 发现服务登记为持久化服务；
9. 在线服务拒绝忘记、离线历史允许忘记；
10. FlyingFox 启动、HTML 初始筛选唯一 `aria-pressed=true`、overview JSON、主机指标、healthz、停止、JS 的动态筛选/age/stale/断连逻辑，以及 POST/PUT/PATCH/DELETE 不命中只读路由；
11. 连续失败阈值、恢复事件和事件去重；
12. 发现失败保留上次快照并标记 stale/failed 元数据；
13. 数据库目录/文件权限与 30 天、10,000 条事件保留上限；
14. stdout/stderr 背压、命令超时和输出上限；
15. 健康检查非法端口/PID、loopback 约束、重定向和超大响应体；
16. Web `/readyz` 503/200、stale 后 503、真实端口停止释放和端口冲突；
17. SQLite 完整性、迁移 marker 和 `VACUUM INTO` 备份可恢复性；
18. 20 个服务的健康探测预算：生成 20 个 snapshot，总耗时小于 5 秒，并验证并发度维持在 2...8；
19. legacy `cockpit.sqlite3` 在未 checkpoint 的 WAL 中保留已提交行，导入后完整性、权限、源文件和失败/目标保护；
20. `ServiceDefinition.validated()` 的本机 HTTP(S)/TCP URL 边界及 file/javascript、userinfo、LAN/公网拒绝。
21. Core snapshot projection 的 starting/coreError/empty/fresh/partial/failed-old、年龄阈值和非法阈值，且 unknown 永不 ready；
22. 生产默认 64 KiB 健康响应上限、64 KiB+1 拒绝，以及多字节 JSON 摘要长度、UTF-8 和敏感 key 脱敏；
23. Task 取消真实长命令快速抛出 `CancellationError` 且子进程退出；
24. 首次 discovery 失败抛错且不 ready，下一次 refresh 成功自愈；
25. 启用服务端口冲突的 save/update 原子失败，disabled 同端口可读且重新启用被拒绝；
26. legacy definitions 与 marker 单事务 rollback、broken services 报错，以及空/注释/claimed 形状不误报；
27. 损坏 SQLite 初始化不覆盖原字节，真实 exclusive lock 保留 stale 快照且无假离线，解锁后恢复；
28. 清除当前目录数据清理 catalog/state/events/failure/action、重置 generation、恢复 defaults，同时保留 schema/marker/legacy 回滚源并删除 preflight；
29. PID 复用改变 stable id，同 host+port 多进程保持 ambiguous，不冒认 PID；
30. ObservationEvidence 旧 JSON 兼容、process fingerprint、host+port match confidence 和 typed health validation；
31. Web `/readyz` 与 overview `typed_state.stale_after_seconds` 的 age/staleAfter 阈值投影和兼容字段、GET-only（overview/services/detail/events/root/healthz/static assets）不触发 discovery，以及 recovery note 不出现在 API 响应；
32. （以上可靠性条目均在临时目录、loopback 或测试子进程中执行，无用户服务启停。）

基线结果：

```text
32 tests total: 10 behavior tests passed; 22 reliability tests passed; 0 skipped
```

## 安全测试原则

- 测试全部使用临时 SQLite 目录；
- 健康检查使用 fake checker 或 LocalOps 自身临时 FlyingFox；
- 不启动、停止或重启 oMLX、LTX、VocalParse、OpenMOSS 等用户服务；
- Web 集成测试使用系统随机端口；
- 打包后烟雾测试可用 `LOCALOPS_APPLICATION_SUPPORT` 指向临时数据目录；
- 测试结束后关闭 FlyingFox 并删除临时目录。

## 打包后回归

本轮已对 `build/LocalOps.app` 和 DMG 结构完成以下自动验证（没有把它们冒充为 macOS 13/UI 浏览器通过）：

- release 构建成功，严格 ad-hoc 签名、arm64、minOS 13.0 和 dSYM 检查通过；
- App bundle 含 GRDB 隐私清单、默认服务 JSON 和完整 Web 资源；
- DMG `hdiutil verify` 与 SHA-256 sidecar 校验通过；
- 只读 Web 的 loopback 绑定、GET-only 路由、CSP 和安全响应头由源码审计及 URLSession XCTest 覆盖；非 GET 矩阵（root/healthz/readyz/overview/services/detail/events × POST/PUT/PATCH/DELETE）全部返回 404，且 generation/events/definitions 保持不变；
- `/readyz` 初始化前/成功后/stale 后的状态由 XCTest 覆盖；
- 真实浏览器证据记录为 1180/900/680/390 px 四档宽度 `overflow=0`，搜索和四档筛选、断连保留/自动重连通过，控制台 warning/error 为 0；
- 重复启动只保留原 PID；正常退出后 8042 在 0.212s 释放；8042 冲突时原生进程继续运行。这些是运行证据，不等同于锁屏环境下的原生 UI 可访问性通过。
- 最终候选 DMG `release/LocalOps-1.0.0-arm64.dmg` 的 SHA-256 为 `8f60e06e843a3bca360ffd7f8dd7c3245fa7da9b336347507ad9d299d05d4b3c`；App 与 dSYM UUID 均为 `30C27DCA-E4C8-3C46-9551-40A533D780B8`。
- 最终打包后 Web 断连实测显示 `state=stale`、标题“连接不可用”，保留 5 张卡片；age 从 27 秒增长到 1 分钟仍继续增长，自动重连清除错误，Chrome 控制台为 0 warning/error。Chrome forced-dark 1180×900 实图无溢出、无截断，状态同时有文字/结构信息而非只靠颜色。

## 兼容与发布回归

- 旧 YAML 迁移、SQLite schema、migration marker、integrity check、WAL 导入和备份恢复使用临时 fixture 自动验证；
- 真实 v0.3 数据库升级、用户数据回滚和目标设备 `/readyz` 仍需人工执行；
- 成功生成 `release/LocalOps-1.0.0-arm64.dmg`，`hdiutil verify` 与 SHA-256 校验有效；
- 测试全程未启动、停止或重启任何用户服务。

## 仍需人工确认

自动化与烟雾测试已覆盖数据、Core、Web 和打包链路。当前 Mac 处于锁屏状态，以下项目仍是明确人工 blocker，不得记为通过：

- 重建候选后菜单栏弹窗、原生管理窗口的打开、刷新、退出、搜索、分类筛选和详情显示；
- VoiceOver 焦点顺序、键盘操作和 200% 字号布局；
- 登记发现服务与忘记服务的确认 sheet；
- 登录时启动开关与系统设置中的显示状态；
- 通知授权和通知开关；
- Web 断连后的重试按钮实际点击与可访问性；
- 干净 macOS 13 arm64 设备的首次启动、升级、回滚和 Gatekeeper 行为（ad-hoc 首次 Control-click → 打开即可，`spctl` rejected 为预期）；
- GitHub release-candidate workflow 在仓库实际运行并保持绿色；
- 从 DMG 拖入 `/Applications` 后首次启动体验。

另见：[30 轮真实行为回归](PRODUCT_TEST_30_ROUNDS.md)。
