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
│       ├── LocalOpsAppModel.swift
│       ├── DashboardWindowController.swift
│       ├── Views.swift
│       └── LegacyBackendCleanup.swift
├── tests/LocalOpsTests/main.swift
├── Scripts/
│   ├── test.sh
│   ├── build-app.sh
│   └── build-dmg.sh
├── Resources/
│   ├── Info.plist
│   ├── AppIcon.svg
│   └── INSTALL.txt
└── docs/
```

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
