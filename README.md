# LocalOps

LocalOps 是一个纯 Swift 的 macOS 菜单栏应用，用来发现、登记和检查这台 Mac 上的本地服务。

开源许可：[MIT License](LICENSE)。

## 当前版本

`v0.4.0` 已将产品运行链路全部迁移到 Swift：

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
swift run LocalOpsTests
```

构建 `.app`：

```bash
./Scripts/build-app.sh
open build/LocalOps.app
```

构建 DMG：

```bash
./Scripts/build-dmg.sh
```

开发构建默认使用 ad-hoc 签名。上传 GitHub 不要求 Apple Developer ID，但没有 Developer ID 签名和 notarization 时，其他用户首次打开需要在 Finder 中按住 Control 点击应用并选择“打开”。

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
