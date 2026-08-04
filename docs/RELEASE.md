# LocalOps v1.0.0 发布与分发说明

本文件描述 v1.0.0 只读目录的候选构建门禁。`v0.4.0` 是历史 Swift 迁移基线，不是当前候选版本。当前仓库没有付费 Apple Developer ID，因此 GitHub 产物使用 ad-hoc 签名；tag 工作流只生成并上传候选 artifact，不自动创建 GitHub Release。

## 本地验证

在 Apple Silicon、macOS 13 或更高版本上运行：

```bash
./Scripts/ci-quality.sh
./Scripts/build-app.sh
./Scripts/build-dmg.sh
```

`ci-quality.sh` 执行 Swift 格式检查、锁文件一致性、release build、XCTest、脚本/Info.plist 语法、OSV 依赖扫描、secret scan、依赖许可证清单和 SPDX SBOM。报告写入被忽略的 `build/ci/`。

打包脚本的约束：

- `Resources/Info.plist` 是版本和 build number 的唯一来源；环境变量只能作为一致性断言；
- 只接受 arm64 二进制，并验证 Mach-O 最低系统版本为 13.0；
- 构建前清理旧 App、图标 staging 和 dSYM，签名后运行 `codesign --verify --deep --strict`；
- 归档 `LocalOps-<version>-<build>-arm64.dSYM`，DMG 运行 `hdiutil verify` 并生成 SHA-256 sidecar；
- ad-hoc 构建的 `spctl` 被 Gatekeeper 拒绝是预期结果；若未来配置 Developer ID，可将 `spctl` 结果作为 post-v1 附加证据。

## GitHub 候选流程

推送形如 `v1.0.0` 的 tag 会触发 `.github/workflows/release-candidate.yml`。工作流先验证 tag 与 `Info.plist` 完全一致，再运行质量门禁和 DMG 构建，最后只上传：

- `LocalOps-<version>-arm64.dmg`；
- `.sha256` 校验文件；
- dSYM 压缩包；
- SPDX SBOM、依赖许可证清单和构建摘要。

维护者必须确认 release-candidate workflow 实际绿色，人工检查候选 artifact，并在干净的 Apple Silicon/macOS 13 设备上安装/退出/升级回滚，然后在 GitHub 页面手动创建 Release。工作流不保存 Developer ID 私钥，也不自动发布或替换线上版本。

本轮 QA 运行证据：重复启动只保留原 PID；正常退出后 `8042` 在 `0.212s` 内释放；固定 `8042` 冲突时原生进程继续运行。真实浏览器已记录 1180/900/680/390 px 四档 `overflow=0`、搜索/四档筛选、断连保留与自动重连、控制台 0 warning/error；GET-only 非 GET 矩阵全部 404 且 generation 不变。

重建后的候选构建身份：`release/LocalOps-1.0.0-arm64.dmg` SHA-256 为 `7c7d3ffc3524dad94feb420308c61439cd8649c5adebca5c1ecb3c3b647524a1`；App 与 dSYM UUID 均为 `30C27DCA-E4C8-3C46-9551-40A533D780B8`。打包后 Chrome forced-dark 1180×900 实图无溢出/截断，状态不只依靠颜色；断连显示 `state=stale`、标题“连接不可用”、保留 5 张卡片，age 从 27 秒增长到 1 分钟仍继续增长，自动重连清错且控制台 0 warning/error。

当前 Mac 处于锁屏状态，菜单栏、原生管理窗口、VoiceOver、200% 字号、通知授权和 Web 断连重试按钮仍是明确人工 blocker，不能把它们写成已通过；这些项目必须在解锁设备和可授权环境中复核。

候选构建还会以 `LOCALOPS_FORBID_XCTSKIP=1` 运行 XCTest；任何未完成的跳过测试都会阻止 tag 工作流。无法在 test target 中可靠模拟的单实例和原生 UI 门禁必须在候选设备上逐项签字：

- 启动两个 LocalOps 实例，确认第二次打开复用现有管理窗口，不创建第二个菜单栏代理或 Web 监听器；
- 在管理窗口连续点击刷新、搜索、分组筛选、登记和忘记，确认按钮可访问、确认 sheet 可取消，且失败提示不丢失；
- 启动/退出/再次启动，确认 `127.0.0.1` 监听端口释放，`/readyz` 从 503 变为 200；
- 从 DMG 安装后首次启动、升级覆盖和回滚，确认用户数据、备份和 Gatekeeper 提示符合安装说明。

## 无 Developer ID 的用户说明

GitHub 下载不等于 Apple notarization。用户必须先校验 SHA-256，再把 App 拖入 `/Applications`；首次启动在 Finder 中 Control-click → 打开，或在系统设置“隐私与安全性”中选择“仍要打开”。不要要求用户全局关闭 Gatekeeper，也不要使用伪造的 Developer ID。

当前分发只支持 arm64/macOS 13+，没有 App Store 包、自动更新或签名 appcast。升级是手动下载、校验和替换；用户应保留旧 DMG 与 `~/Library/Application Support/LocalOps/` 备份，以便回滚。安装、回滚和卸载步骤见 [Resources/INSTALL.txt](../Resources/INSTALL.txt)。

## Developer ID（post-v1 可选改善）

v1.0.0 免费 GitHub ad-hoc 分发不要求 Developer ID 或 notarization。未来若获得 Apple Developer Program，可按下列清单改善用户首次启动体验；这些步骤不是 v1 发布 blocker：

1. 使用 Developer ID Application 和 hardened runtime 签名嵌套 bundles；
2. 用 `xcrun notarytool submit --wait` 完成 notarization；
3. `xcrun stapler staple`/`validate` DMG 或 App；
4. 在干净设备上运行 `spctl --assess --type execute` 并记录结果；
5. 将签名、notarization 和 Gatekeeper 结果作为后续版本的附加证据。

Developer ID 不能替代 URL/数据隐私、迁移完整性、Web loopback 和退出释放端口等 Core 门禁。
