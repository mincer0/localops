# LocalOps 隐私说明

更新日期：2026-08-04

LocalOps v1 是本机只读目录，不上传遥测，也没有 LocalOps 云端账号或远程控制服务。应用默认只在本机运行，信息页绑定 `127.0.0.1`；它不会因为打开浏览器页面而把数据发送到局域网或互联网。

## 处理的数据

为了展示本机服务，应用可能读取并保存：

- 用户登记的服务名称、分组、入口 URL 和健康检查规则；
- `lsof`/`ps` 能看到的监听地址、端口、PID、进程名、可执行文件路径、工作目录、CPU 和内存摘要；
- 已登记服务的健康状态、延迟、状态变化事件和有限的健康响应摘要；
- 运行期间的内存、磁盘、CPU Load、开机时长和 macOS 热状态。

主机指标不会写入服务注册表。服务定义、状态、发现历史和事件保存在：

```text
~/Library/Application Support/LocalOps/.data/localops.sqlite3
```

旧版 `services.yaml`、`claimed-services.yaml` 只用于升级读取，并按原路径保留，便于回滚。

## 网络边界

LocalOps 的 Web 页面和 GET API 只绑定 `127.0.0.1`，没有 POST/PUT/PATCH/DELETE 控制路由。它不会启动、停止、重启、杀死进程，也不会执行任意 shell 命令。

健康检查会按照用户登记的规则发起 HTTP 或 TCP 请求。请只配置可信的本机地址，不要在 URL 中放密码、Bearer token、API key 或其他秘密；服务返回的 JSON 摘要可能包含服务自己返回的内容。不要把本机目录或响应摘要复制到公开 issue。

## 权限、保留和删除

应用不要求管理员权限，不安装 LocalOps 自身的 LaunchAgent。登录启动是用户在设置中主动打开的 macOS 登录项。状态事件按 30 天保留，并且数据库最多保留最近 10,000 条事件；清理在每次 refresh 后执行。LocalOps 不检查、卸载或删除旧 LaunchAgent；如用户确认存在遗留项，退出 LocalOps 后按安装/迁移说明手动处理，其他同名或未知任务由用户自行决定。

设置中的“清除当前目录数据”只清除 LocalOps 当前数据库中的服务定义、状态、发现目录、事件、失败计数和 action audit，随后重置 generation 并恢复内置默认服务。它保留 SQLite schema、migration marker、旧 YAML/legacy SQLite 回滚源；事务、完整性检查和备份清理成功后才删除 preflight 备份，失败不会留下半清除状态。

卸载应用不会自动删除数据。要删除全部 LocalOps 数据，请先退出应用、关闭登录启动，然后在确认不需要回滚后删除 `~/Library/Application Support/LocalOps/`。删除前建议复制整个目录作为备份。

## 第三方组件

应用使用 GRDB/SQLite 保存本地数据，并使用 FlyingFox 提供本机 HTTP 服务。依赖版本、许可证和 SBOM 在 CI 质量门禁中检查；发布候选产物会附带构建信息。

如发现安全问题，请先通过 GitHub 私下联系维护者，不要在公开 issue 中粘贴数据库、服务 URL 或健康响应。
