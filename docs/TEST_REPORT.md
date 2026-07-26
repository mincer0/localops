# LocalOps v0.4 Swift 迁移测试报告

测试日期：2026-07-26

## 自动化覆盖

`swift run LocalOpsTests` 当前覆盖：

1. 默认 JSON 服务的校验和唯一 id；
2. IPv4、IPv6 和 wildcard 监听地址解析；
3. 历史服务 id 不依赖 PID；
4. 旧 YAML 服务的纯 Swift 迁移；
5. GRDB schema、服务定义、事件和发现历史持久化；
6. 内存、磁盘、CPU Load、逻辑核心、开机时长和热状态采集；
7. Engine 合并已登记、待登记和最近掉线服务；
8. 发现服务登记为持久化服务；
9. 在线服务拒绝忘记、离线历史允许忘记；
10. FlyingFox 启动、HTML、overview JSON、主机指标、healthz 和停止；
11. POST 请求不命中只读路由。

基线结果：

```text
10/10 Swift tests passed
```

## 安全测试原则

- 测试全部使用临时 SQLite 目录；
- 健康检查使用 fake checker 或 LocalOps 自身临时 FlyingFox；
- 不启动、停止或重启 oMLX、LTX、VocalParse、OpenMOSS 等用户服务；
- Web 集成测试使用系统随机端口；
- 打包后烟雾测试可用 `LOCALOPS_APPLICATION_SUPPORT` 指向临时数据目录；
- 测试结束后关闭 FlyingFox 并删除临时目录。

## 打包后回归

本轮已对 `build/LocalOps.app` 完成以下验证：

- release 构建成功，严格 ad-hoc 签名验证通过；
- App 内含 GRDB 隐私清单、默认服务 JSON 和完整 Web 资源；
- 用 `LOCALOPS_APPLICATION_SUPPORT` 指向临时目录启动，未修改正式数据；
- FlyingFox 只监听 `127.0.0.1:8042`；
- `/`、`/api/v1/overview` 和 `/readyz` 正常响应；
- overview API 返回热状态、CPU Load、核心数、磁盘总量和开机时长；
- 机器状态 Web 区域在 680px 窄窗口无横向溢出且无控制台错误；
- HTML 响应包含 CSP、`no-store`、`nosniff` 和 `no-referrer`；
- 对 `/api/v1/overview` 发出 POST 得到 404；
- 退出 App 后确认 8042 端口已释放。

## 兼容与发布回归

- 在真实 v0.3 数据库和 YAML 的副本上启动 Swift App；
- 保留原有状态和事件，补齐 Swift schema；
- 将旧 oMLX、LTX 定义导入 SQLite；
- migration 后 `/readyz` 返回 ready；
- 成功生成 `release/LocalOps-0.4.0-arm64.dmg`；
- `hdiutil verify` 校验 DMG 有效；
- 全程未启动、停止或重启任何用户服务。

## 仍需人工确认

自动化与烟雾测试已覆盖数据、Core、Web 和打包链路。发布前仍建议在目标 Mac 上人工点击确认：

- 菜单栏弹窗的打开、刷新和退出；
- App 已运行时再次打开是否显示管理窗口；
- 管理窗口的搜索、分类筛选和详情显示；
- 登记发现服务与忘记服务的确认 sheet；
- 登录时启动开关与系统设置中的显示状态；
- 从 DMG 拖入 `/Applications` 后首次启动体验。

另见：[30 轮真实行为回归](PRODUCT_TEST_30_ROUNDS.md)。
