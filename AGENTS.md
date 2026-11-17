# AGENTS.md

本文件面向在本仓库中工作的 AI agent 与新加入的贡献者。回答使用中文，先给结论再给细节。

## 项目概况

ClashBar 是原生 macOS 菜单栏代理客户端（SwiftUI + AppKit），网络能力由 `mihomo` 内核提供，通过 mihomo 的 External Controller HTTP / WebSocket API 管理配置、节点、规则、连接与系统代理。

- 语言与工具链：Swift 6.2（`// swift-tools-version: 6.2`）、SwiftPM、macOS 13+
- 依赖：无第三方 Swift 包，全部基于系统框架（AppKit、SwiftUI、Network、ServiceManagement）
- 体积目标：无 Core 的 `.app` 约 3 MB，避免引入重量级依赖

## 常用命令

```sh
make build                 # 产出 dist/ClashBar.app（默认不打包 mihomo）
make build WITH_CORE=1     # 连同 mihomo 二进制一起打包
make dist WITH_CORE=1      # app + dmg
make format                # swiftformat . + swiftlint lint
make clean                 # 清理 .build / dist / .swiftpm / Packages

swift build                # 只编译，不打包；最快的验证手段
swift build -c release
```

- 提交前至少跑 `swift build`；改动涉及格式时跑 `make format`（先 format 再 lint，两者必须都通过）。
- 打包链路：`Scripts/build.sh <preprocess|package|dmg|app|all>`，内部串联 `preprocess.sh`（下载 / 校验 mihomo、生成 `.icns`）、`package_app.sh`（组装 `.app`）、`make_dmg.sh`。
- 仓库没有测试 target，也没有单元测试。验证方式以编译通过 + 手工运行 `.app` 为主，不要假装存在测试套件。
- 文档站位于 `docs/`（Next.js + Fumadocs，pnpm）：`cd docs && pnpm dev`，校验用 `pnpm types:check`。

## 代码结构

```
Sources/
  ClashBar/
    App/            入口与依赖装配：ClashBarApp、AppDelegate、AppDependencies
    ViewModels/     AppViewModel 及其按功能拆分的扩展、各 Store、Tab ViewModel
    Views/          MenuBar（各 Tab 与 Root 布局）、StatusBar（状态栏项）
    Services/       与外界交互的能力层：Core、Config、MihomoAPI、SystemProxy、Tun、Stream 等
    Models/         纯数据模型与 Codable 解析
    Core/           UI 基础（本地化、布局 token、组件）、Utils、Extensions
    Resources/      Assets、Localizable.strings、ConfigTemplates、bin/mihomo（不入库）
  ProxyHelper/      系统代理特权守护进程（Daemon/main.swift、LaunchDaemons plist）
  ProxyHelperShared/ App 与 Helper 共用的协议与常量
Scripts/            构建、打包、DMG、发布说明生成
docs/               文档站
```

关键点：

- `AppViewModel` 是唯一的应用状态中心，按功能拆成 `AppViewModel+*.swift` 扩展（SystemProxy、Tun、Proxy、Polling、Streams、Persistence、Alerts、Lifecycle 等）。新增状态优先加到既有扩展，不要新造平行的状态容器。
- 高频数据用 `@Published` 会拖慢菜单栏，所以流量、代理、连接、日志分别放在 `Stores/`（`TrafficStore`、`ProxyStore`、`ConnectionsStore`、`LogsStore`），由 `AppViewModel` 暴露计算属性转发。
- `AppDependencies` 用 struct + `static var live` 做依赖注入，View Model 只依赖协议或具体 Service，便于构造替身。
- 与 mihomo 的所有 HTTP 调用都走 `MihomoAPIService` 的 `Endpoint` 枚举；新增接口就在枚举里加 case，并补 `method` / `path` / `queryItems` / `body` / `timeoutInterval`。
- WebSocket 长连接统一由 `StreamCoordinator` 管理重连与去抖，不要在 View 层自己建任务。
- 系统代理与 TUN 需要特权：App 通过 `AdministratorShell`（osascript 管理员授权）安装 `ProxyHelper` 到 `/Library/PrivilegedHelperTools`，XPC 走 `ProxyHelperShared` 协议。改动 Helper 时同时考虑版本号（`ProxyHelperConstants.helperVersion`）与升级重装路径。
- 运行时数据目录：`~/Library/Application Support/clashbar`，内置内核复制到该目录下 `core/mihomo`。

## 编码约定

**并发**

- 全部 UI 与状态类型标注 `@MainActor`；跨线程的 Service 用 `Sendable` / `@unchecked Sendable` 并自行加锁。
- 需要显式 `self` 的成员引用保持 `self.` 写法（SwiftFormat 配置为 `--self insert`，SwiftLint 也关闭了 `explicit_self`）。
- 注意 Swift 6 严格并发：不要在 `Task` 里捕获非 Sendable 的可变状态，跨 actor 用 `MainActor.assumeIsolated` 或显式调度。

**风格**

- 缩进 4 空格，行宽上限 120，LF 换行。
- 扩展成员用 `MARK: - Type + Member` 分组（SwiftFormat 会生成）。
- 省略多余的花括号返回写法保持项目现状（大量 `if` 表达式、省略 `return` 的隐式返回）。
- 不写无意义注释；仅当逻辑不自明时才加注释。默认不新增注释。

**本地化**

- 所有面向用户的文案必须走 `tr("...")` / `L10n.t(...)`，key 命名形如 `ui.tab.proxy`、`app.settings.saved.*`、`log.system_proxy.*`。
- 新增 key 时同步修改 `Sources/ClashBar/Resources/Localization/zh-Hans.lproj/Localizable.strings` 与 `en.lproj/Localizable.strings`，两处必须成对出现。
- 支持语言只有 `zh-Hans` 与 `en`；中文为默认回退。

**格式化与静态检查**

- `.swiftformat` 与 `.swiftlint.yml` 是唯一标准，不要引入新规则或覆盖项。
- `Sources/ClashBar/Resources` 在 SwiftLint 中排除，二进制与资源文件不要手工编辑。

## 提交与发布

- 本仓库是 `Sitoi/ClashBar` 的 fork，分支模型、上游同步与分家流程见 [docs/MAINTENANCE.md](docs/MAINTENANCE.md)。
- `main` 只放可回流上游的改动（bug 修复、测试、工程改进），靠 `Scripts/sync_upstream.sh` rebase 到上游之上。
- 与上游必然冲突的改动（仓库标识、发布流程）放 `fork/*` 分支，不要合进 `main`。
- 提交信息沿用仓库风格：`<emoji> <type>: <中文摘要>`，例如 `✨ feat: 更新 v0.3.6，修复系统代理 Helper 安装问题`。
- 只有在用户明确要求时才提交 git；不要主动 commit、push 或打 tag。
- 版本发布由 GitHub Actions 驱动：`.github/workflows/release-dmg.yml`（tag 触发，构建 arm64 / x86_64 各含 Core 与不含 Core 的 DMG，并更新 Homebrew cask）与 `release-dmg-beta.yml`（从 `alpha` 分支手动触发，发布 prerelease）。
- 每个版本需要在 `CHANGELOG.md` 顶部补一节：版本标题、徽章行、一段 `>` 摘要，再按「✨ 新增功能 / 🚀 优化改进 / 🐞 修复问题」分类，每条前置对应徽章图片。文档站的更新日志页直接解析该文件，格式不一致会导致解析失败。
- 发版时需要同步更新 `CHANGELOG.md` 与文档站相关内容；`docs/content/docs/changelog.mdx` 为自动生成，不手工维护内容。

## 常见坑

- 系统代理依赖打包后的 `.app` 位于 `/Applications`；直接 `swift run` 运行会缺少 Helper 上下文，相关报错属于预期。
- Helper 从被隔离的 `.app` 安装会继承 `com.apple.quarantine`，导致 launchd 拒绝加载；安装脚本已显式 `xattr -c` 并在 bootstrap 前校验，改动安装流程时不要破坏这一点。
- 菜单栏 UI 有固定宽度与高度上报逻辑（`HeightReportingModifier`、`PopoverLayoutModel`），改动布局时要验证面板尺寸不抖动。
- 快捷操作菜单的 `.disabled(...)` 状态需要观察 `AppViewModel`，历史上因为内联在 `App` 里导致状态冻结；新增命令请走 `AppCommands`。
- 状态栏流量曲线使用固定 60 点滑动窗口，不要改成按数据长度拉伸。
