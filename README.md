# LocalOps

LocalOps 是一个纯 Swift 的 macOS 菜单栏应用，用来发现、登记和检查这台 Mac 上的本地服务。

开源许可：[MIT License](LICENSE)。

v1 支持 Apple Silicon（`arm64`）和 macOS 13 或更高版本。菜单栏、原生管理窗口和回环 Web 页面共享同一份状态，但都不会控制其他服务。

## 当前版本

`v1.0.0` 是当前本地发布候选（尚未创建 tag 或 GitHub Release）；它沿用 `v0.4.0` Swift 迁移基线，并将可靠性、只读 Web、原生设置和诊断导出纳入候选门禁。`v0.4.0` 仅作为历史基线保留：

- SwiftUI 菜单栏与原生管理窗口；
- Swift Actor 状态内核；
- `lsof` 只读端口发现；
- `URLSession` HTTP 健康检查；
- `Network.framework` TCP 健康检查；
- GRDB / SQLite 服务注册表、历史与事件；
- macOS 热状态、CPU Load、内存、磁盘和开机时长；
- FlyingFox 提供的本机只读信息页；
- 对旧版 `services.yaml` 和 `claimed-services.yaml` 的一次性升级读取。

运行时不再依赖 Python、FastAPI、Jinja、PyInstaller、`uv` 或独立 `localopsd`。

## 产品边界

LocalOps 当前可以：

- 显示已登记服务是否在线；
- 区分“进程正在运行”和“API 健康”；
- 发现新的本机监听端口；
- 将发现项登记为只读服务；
- 记住已经掉线的历史服务；
- 打开服务原有的 Web/API 入口。
- 在原生界面和只读 Web 查看机器运行状态。

温控指标使用 macOS 官方热状态（正常、偏热、严重、临界），无需管理员权限。macOS 没有稳定公开的摄氏温度 API，因此 LocalOps 不调用私有 SMC 接口，也不显示来源不可靠的温度数字。

当前不实现服务的启动、停止和重启。CLI、launchd、macOS App 和容器的统一管理方式留待后续确定。

FlyingFox 随 `LocalOps.app` 启动，只监听 <http://127.0.0.1:8042>。Web 页面没有 POST、PUT 或 DELETE 控制路由。

## 开发

需要 macOS 13 或更高版本以及 Swift 6.1+。

```bash
swift build
swift test
```

当前候选的 XCTest 门禁为 32 项真实断言（10 项行为 + 22 项可靠性），禁止以 `XCTSkip` 代替覆盖。

构建 `.app`：

```bash
./Scripts/build-app.sh
open build/LocalOps.app
```

构建 DMG：

```bash
./Scripts/build-dmg.sh
```

`Resources/Info.plist` 是版本和 build number 的唯一来源；打包脚本会拒绝环境变量、架构或最低系统版本漂移。开发构建默认使用 ad-hoc 签名。GitHub 免费分发不要求 Apple Developer ID，但没有 Developer ID 签名和 notarization 时，其他用户首次打开需要在 Finder 中按住 Control 点击应用并选择“打开”。

## 数据

```text
~/Library/Application Support/LocalOps/
├── .data/localops.sqlite3
└── config/
    ├── services.yaml          # 旧版迁移来源，不再是运行配置
    └── claimed-services.yaml  # 旧版迁移来源
```

新版的服务定义、健康状态、历史发现和事件统一保存在 SQLite。

详细资料：

- [架构](docs/ARCHITECTURE.md)
- [代码结构](docs/CODE_STRUCTURE.md)
- [实施计划](docs/PLAN.md)
- [测试报告](docs/TEST_REPORT.md)
- [30 轮真实行为回归](docs/PRODUCT_TEST_30_ROUNDS.md)
- [发布说明](docs/RELEASE.md)
- [隐私说明](docs/PRIVACY.md)

## 安装、升级和卸载

从 GitHub Release 下载带有 `.sha256` 的 arm64 DMG，先用 `shasum -a 256` 校验，再把 App 拖入 `/Applications`。首次打开 ad-hoc 构建时，在 Finder 中按住 Control 点击 App，选择“打开”；不要为了 LocalOps 全局关闭 Gatekeeper。

升级前退出 LocalOps，并备份 `~/Library/Application Support/LocalOps/`。下载并校验新的 DMG 后替换 `/Applications/LocalOps.app`；当前没有内置自动更新或一键回滚，保留旧 DMG 即可手动恢复。卸载时先关闭“登录后自动启动”、退出 App，再移除 App；确认不需要历史和迁移回滚文件后，才删除 Application Support 目录。完整步骤见 [安装说明](Resources/INSTALL.txt) 和 [发布说明](docs/RELEASE.md)。
