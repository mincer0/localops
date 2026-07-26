# LocalOps v0.4.0 发布说明

v0.4.0 是纯 Swift 架构切换版本。

## 重要变更

- 删除 Python、FastAPI、Jinja、PyInstaller 和 `localopsd`；
- 不再安装 LocalOps 自身的 LaunchAgent；
- 原生 UI 直接读取 Swift Actor；
- 新增 SwiftUI 管理窗口；
- 新增 FlyingFox 只读信息页；
- 新增无需提权的机器热状态、CPU Load、磁盘和开机时长；
- 服务定义迁入 SQLite；
- 保留旧 YAML 的一次性迁移；
- 服务启停暂不开放，等待后续产品方案确定。

## 构建

```bash
swift run LocalOpsTests
./Scripts/build-app.sh
./Scripts/build-dmg.sh
```

设置正式签名身份：

```bash
CODESIGN_IDENTITY="Developer ID Application: ..." ./Scripts/build-dmg.sh
```

GitHub 发布不强制需要 Developer ID。默认 ad-hoc 版本可以发布，但 Gatekeeper 不会像已公证版本那样直接信任它。

## 升级

首次启动 v0.4 时：

1. 保留旧数据和 YAML；
2. 升级 SQLite schema；
3. 导入旧服务定义；
4. 安全卸载旧 LocalOps/Cockpit 后台 LaunchAgent；
5. 启动单进程 Swift App 和只读 FlyingFox。

建议正式发布前用一份 Application Support 副本完成升级回归。
