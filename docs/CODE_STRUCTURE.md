# LocalOps 代码结构

```text
LocalOps/
├── Package.swift
├── Package.resolved
├── Sources/
│   ├── LocalOpsCore/
│   │   ├── Models.swift
│   │   ├── LocalOpsEngine.swift
│   │   ├── LocalOpsStore.swift
│   │   ├── ServiceDiscovery.swift
│   │   ├── HealthChecker.swift
│   │   ├── SystemMetricsReader.swift
│   │   ├── LegacyServiceMigrator.swift
│   │   └── Resources/DefaultServices.json
│   ├── LocalOpsWeb/
│   │   ├── LocalWebServer.swift
│   │   └── Resources/Web/
│   └── LocalOpsApp/
│       ├── main.swift
│       ├── AppDelegate.swift
│       ├── DiagnosticsExporter.swift
│       ├── LocalOpsInstanceLock.swift
│       ├── LocalOpsAppModel.swift
│       ├── LocalURLPolicy.swift
│       ├── NotificationCoordinator.swift
│       ├── SnapshotProjection.swift
│       ├── DashboardWindowController.swift
│       └── Views.swift
├── tests/LocalOpsTests/
│   ├── LocalOpsTests.swift
│   └── ReliabilityTestSkeleton.swift
├── Scripts/
│   ├── ci-quality.sh
│   ├── test.sh
│   ├── build-app.sh
│   └── build-dmg.sh
├── Resources/
│   ├── Info.plist
│   ├── AppIcon.svg
│   └── INSTALL.txt
└── docs/
```

GitHub Actions 在 `.github/workflows/ci.yml` 和
`.github/workflows/release-candidate.yml` 中锁定 arm64 `macos-15`、Xcode
16.4/Swift 6.1，并复用 `Scripts/ci-quality.sh` 的格式、构建、测试、安全和
供应链报告门禁。

依赖方向是单向的：

```text
LocalOpsApp ──→ LocalOpsWeb ──→ LocalOpsCore
      └──────────────────→ LocalOpsCore

LocalOpsCore ──→ GRDB
LocalOpsWeb  ──→ FlyingFox
```

`LocalOpsCore` 不导入 SwiftUI、AppKit 或 FlyingFox，因此可以独立测试。`LocalOpsWeb` 不访问 SQLite，只通过 Engine 读取 snapshot。

扩展原则：

- 新健康类型：在 `ServiceHealthCheck` 和 `HealthChecking` 中增加；
- 新发现来源：实现 `ServiceDiscovering`；
- 新持久化字段：添加 GRDB migration，不覆盖旧表；
- 新 Web 信息：先加入 Core snapshot，再由 GET API 序列化；
- 未来启停 adapter：建立独立 target，不把 `Process` 命令拼装放进 View。
