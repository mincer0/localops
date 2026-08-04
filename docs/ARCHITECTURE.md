# LocalOps 详细架构

更新日期：2026-08-04
架构版本：6.0
目标产品：v1.0.0 本地发布候选（基于 v0.4.0 历史纯 Swift 基线）

## 1. 一句话架构

LocalOps 是一个单进程、原生 macOS 菜单栏应用：SwiftUI 和 FlyingFox 共享同一个 `LocalOpsEngine` Actor，GRDB / SQLite 保存服务、历史和事件，macOS 系统适配器负责只读发现与健康检查。

```mermaid
flowchart TB
    U["用户"] --> M["SwiftUI 菜单栏"]
    U --> N["SwiftUI 管理窗口"]
    U --> B["浏览器 · 只读"]

    M --> C["LocalOpsEngine Actor"]
    N --> C
    B --> F["LocalWebServer Actor · FlyingFox"]
    F --> C

    C --> R["Service Registry"]
    C --> D["Discovery · lsof"]
    C --> H["Health Checker"]
    C --> DB[("GRDB / SQLite")]

    H --> HTTP["URLSession · HTTP"]
    H --> TCP["Network.framework · TCP"]
    H --> PID["Darwin · PID"]
    HTTP --> S["本地服务自己的 API"]
    TCP --> S
    D --> S
```

## 2. 两种 API 必须分开

### 2.1 用户服务自己的 API

oMLX、LTX、数据库或开发服务可以自己提供 API。LocalOps 对它们只做：

- 按配置的 URL 发出健康检查；
- 记录 HTTP 状态、延迟和有限 JSON 摘要；
- 连接失败时显示离线原因；
- 在原生界面或只读 Web 页打开服务入口。

LocalOps 不控制“服务内部 API 开关”。服务的 API 是否启用由该服务自己的配置决定。

### 2.2 LocalOps 的只读 Web 服务

FlyingFox 嵌入 `LocalOps.app`，不是独立后台，也不是服务控制面。

```text
GET /                         只读信息页
GET /healthz                  LocalOps Web 存活
GET /readyz                   Core 是否已初始化
GET /api/v1/overview          状态总览
GET /api/v1/services          服务列表
GET /api/v1/services/:id      服务详情
GET /api/v1/events            最近事件
```

不注册 POST、PUT、PATCH 或 DELETE 路由。Web 页面每 15 秒读取一次 Core 已缓存的 snapshot，不会因为浏览器请求而执行新的 `lsof` 扫描。

## 3. 进程边界

v1.0.0 只有一个产品进程：

```text
LocalOps.app/Contents/MacOS/LocalOps
├── AppKit NSStatusItem
├── SwiftUI Views
├── LocalOpsEngine Actor
├── LocalWebServer Actor
└── SQLite connection
```

不再存在：

- `localopsd`；
- LocalOps 自身的 LaunchAgent；
- Swift 客户端到 Python 后端的 HTTP 通信；
- Python 虚拟环境或 PyInstaller 二进制；
- FastAPI / Jinja 运行时。

退出 `LocalOps.app` 会同时结束菜单栏、管理窗口和 FlyingFox。用户的本地服务不受影响。

## 4. Core Actor

`LocalOpsEngine` 是唯一业务入口，负责：

1. 执行数据库 migration；
2. 导入旧 YAML 定义并插入默认服务；
3. 加载已启用的服务定义；
4. 运行只读端口发现；
5. 并发执行 HTTP / TCP / PID 检查；
6. 组装登记、待登记和历史掉线 snapshot；
7. 保存状态变化与事件；
8. 计算 `SnapshotMetadata` 和 `LocalOpsSnapshotProjection`，将 starting/partial/stale/coreError 与 ready 规则统一提供给 UI/Web；
9. 向 SwiftUI 和 FlyingFox 返回不可变的 `LocalOpsOverview`。

SwiftUI 不直接访问 GRDB，FlyingFox 也不重新实现健康检查。

## 5. 服务状态模型

生命周期和健康度是两个维度：

```text
lifecycle: unknown | stopped | running
health:    unknown | healthy | degraded | unhealthy
```

| 组合 | 含义 |
|---|---|
| `running + healthy` | 进程与业务接口均正常 |
| `running + unhealthy` | 端口有进程，但健康地址返回错误或连接失败 |
| `stopped + unhealthy` | 未找到监听进程且健康检查失败 |
| `running + unknown` | 扫描到端口，但未登记健康规则 |
| `unknown + unknown` | 没有足够信息判断 |

当 HTTP 检查失败但配置端口仍有监听进程时，Core 保留 `running + unhealthy`，避免把错误路径或 HTTP 500 误判为进程已停止。

`lifecycle`、`health`、`presence` 和 observation freshness/状态彼此独立。连续一次失败只进入 degraded/partial；第二次连续失败才确认 stopped，恢复后记录一次 recovered 事件。发现扫描失败时保留上一次 snapshot，metadata 标为 stale/failed，不把未扫描到误报为离线。

## 6. 发现与历史身份

发现器固定调用：

```text
/usr/sbin/lsof -nP -iTCP -sTCP:LISTEN -Fpcn
```

它不读取完整命令行，避免把可能的 token 或密钥保存到 SQLite。对每个进程只补充：

- 可执行文件路径；
- 工作目录；
- RSS 内存；
- CPU 占用；
- PID、端口和监听地址。

`CommandRunner` 只为上述只读发现启动 `lsof`/`ps` 子进程；超时、输出超限或
取消时只终止它自己创建的子进程，不接受服务启停命令。

历史 id 由下列材料的 SHA-256 前 16 个十六进制字符生成：

```text
executable_path \0 normalized_host \0 port
```

因此进程重启换 PID 后仍是同一条历史记录。

监听进程另有不含 PID 的 `processFingerprint`（进程名、可执行路径和工作目录）；匹配结果通过 `ObservationMatchConfidence` 表达 host/port、ambiguous 或 none。相同 host+port 的多个进程不会冒认其中一个 PID。

## 7. 主机运维指标

`SystemMetricsReader` 在每次 Core 刷新时直接读取本机状态：

| 指标 | 来源 | 说明 |
|---|---|---|
| 内存 | Mach `host_statistics64` | 已用、总量和比例 |
| 磁盘 | `URLResourceValues` | 可用、总量和已用比例 |
| CPU Load | Darwin `getloadavg` | 1、5、15 分钟系统负载 |
| 逻辑核心 | `ProcessInfo` | 用于解释 Load 数值 |
| 开机时长 | `ProcessInfo.systemUptime` | 不依赖外部命令 |
| 热状态 | `ProcessInfo.thermalState` | 正常、偏热、严重或临界 |

热状态是 macOS 实际用于系统降频与保护决策的公开信号。精确摄氏温度需要私有 SMC 或特权工具，不具备稳定兼容性，因此当前不采集。所有主机指标都无需 `sudo`，不启动额外常驻进程，也不写入数据库。

## 8. 持久化

主数据库：

```text
~/Library/Application Support/LocalOps/.data/localops.sqlite3
```

| 表 | 用途 |
|---|---|
| `services` | 服务定义、endpoint 和健康规则 |
| `service_state` | 已登记服务的最新状态 |
| `events` | 上线、掉线、恢复和健康变化 |
| `service_catalog` | 自动发现和最近掉线记录 |
| `action_audit` | 为未来受控启停保留的兼容表，v1.0.0 不写入（沿自 v0.4.0 基线） |
| `localops_migrations` | 一次性迁移 marker |
| `localops_refresh_state` | generation、最近尝试和成功时间 |
| `service_failure_state` | 连续失败计数与恢复阈值 |

`DefaultServices.json` 仅用于首次插入 oMLX 和 LTX Studio 等默认条目。用户数据不会因为 App 升级被覆盖。
事件按 30 天保留，且最多保留最近 10,000 条。

## 9. 旧版迁移

启动顺序：

1. 如果 `localops.sqlite3` 不存在但 `cockpit.sqlite3` 存在，通过 SQLite `VACUUM INTO` 创建一致快照，执行 integrity check，再原子移动到目标；不直接复制可能遗漏 WAL 的主文件；
2. GRDB 以 `IF NOT EXISTS` 方式补充 Swift 版 schema；
3. 用纯 Swift 的有限迁移解析器读取旧 `services.yaml` 与 `claimed-services.yaml`；
4. 将条目与 migration marker 在同一事务中 `INSERT OR IGNORE`，解析或校验失败时整笔 rollback；
5. 旧 YAML、legacy SQLite 保留在磁盘上作为回滚备份，不再是运行时依赖；
6. LocalOps 不检查、卸载或删除旧 LaunchAgent。若用户确认仍有遗留项，退出
   LocalOps 后按安装/迁移说明手动处理；未知或同名任务始终由用户决定。

迁移不删除旧数据库或 YAML。

## 10. 并发模型

- `LocalOpsEngine` Actor 串行化 snapshot 组装和业务状态；
- GRDB `DatabaseQueue` 再保证 SQLite 访问顺序；
- HTTP / TCP 检查用 task group 并发执行，上限 8 个 worker；
- 命令 runner 仅服务于只读 `lsof`/`ps` 发现，同时消费 stdout/stderr，具备输出上限、timeout 和 Task cancellation 终止路径；
- SwiftUI 模型限定在 `MainActor`；
- FlyingFox 路由只读取 Engine 的 cached overview；
- TCP 探测用一次性 continuation gate 避免超时与连接回调重复 resume。

## 11. 安全边界

- FlyingFox 固定绑定 `127.0.0.1`；
- 不添加 CORS 头；
- Web 只有 GET；
- HTML 使用 Content Security Policy；
- 前端使用 DOM `textContent` 显示服务数据，不把扫描内容插入 `innerHTML`；
- 发现项默认只读；
- 不接受任意 shell 字符串；
- 进程健康检查只调用 `kill(pid, 0)` 探活（包含 EPERM 时的存在性判断），不发送终止信号；
- 健康 URL 仅允许 loopback HTTP(S) 且禁止 userinfo/重定向；响应上限 64 KiB，JSON 摘要最多 2 KiB 并脱敏 token/password/API key；
- 数据目录使用 0700、SQLite 文件使用 0600，清除当前目录数据保留 schema、migration marker 和 legacy 回滚源；
- v1.0.0 不包含任何服务启停实现。

因为只读 Web 没有控制能力，v1.0.0 不要求 Bearer Token。如果未来开放局域网或增加操作路由，必须重新引入认证、CSRF 防护和操作审计。

## 12. 启停管理的预留边界

未来可能的 adapter：

```text
observe
app
cli
launchd
container
```

`managementKind` 目前只作为描述性元数据写入服务定义，永不执行对应 CLI、launchd、App 或容器操作。v1.0.0 的数据模型不将启停行为写死。只有确定下列问题后才实现：

- 什么样的官方 CLI 才能被认为可靠生命周期接口；
- 前台进程是否由 LocalOps 托管；
- LocalOps 退出时托管进程如何存活；
- 何时自动生成 LaunchAgent；
- 如何做命令确认、超时、幂等和审计。

这使 v1.0.0 可以先成为可靠的本地服务目录，而不会在管理方式尚未明确时引入危险控制面。
