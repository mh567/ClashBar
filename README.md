<div align="center">

<img src="./docs/public/clashbar-logo.png" width="220" alt="ClashBar Logo" />

# ClashBar

原生 macOS 菜单栏代理客户端，基于 `SwiftUI + AppKit`，由 `mihomo` 驱动。  
轻量、稳定，在菜单栏完成配置、节点、规则、连接与系统代理管理。 ✨

> **本仓库是 [Sitoi/ClashBar](https://github.com/Sitoi/ClashBar) 的 fork。**  
> 安装包、应用内更新、版本号与文档都以本仓库为准，与上游的 `0.3.x` 版本和 Homebrew tap 相互独立。

<p>
  <img alt="Platform" src="https://img.shields.io/badge/macOS-13%2B-111111?style=flat-square&logo=apple" />
  <img alt="Swift" src="https://img.shields.io/badge/Swift-6.2-F05138?style=flat-square&logo=swift" />
  <img alt="Build" src="https://img.shields.io/badge/Build-SwiftPM-0A84FF?style=flat-square" />
  <img alt="i18n" src="https://img.shields.io/badge/i18n-zh--Hans%20%7C%20en-34C759?style=flat-square" />
  <a href="https://github.com/mh567/ClashBar/releases" target="_blank" rel="noopener noreferrer">
    <img alt="Version" src="https://img.shields.io/github/v/release/mh567/ClashBar?style=flat-square&logo=github" />
  </a>
  <a href="https://github.com/mh567/ClashBar/stargazers" target="_blank" rel="noopener noreferrer">
    <img alt="Stars" src="https://img.shields.io/github/stars/mh567/ClashBar?style=flat-square&logo=github" />
  </a>
  <a href="https://github.com/mh567/ClashBar/issues" target="_blank" rel="noopener noreferrer">
    <img alt="Issues" src="https://img.shields.io/github/issues/mh567/ClashBar?style=flat-square&logo=github" />
  </a>
  <a href="https://github.com/mh567/ClashBar/pulls" target="_blank" rel="noopener noreferrer">
    <img alt="PRs" src="https://img.shields.io/github/issues-pr/mh567/ClashBar?style=flat-square&logo=github" />
  </a>
  <a href="https://github.com/mh567/ClashBar/network/members" target="_blank" rel="noopener noreferrer">
    <img alt="Forks" src="https://img.shields.io/github/forks/mh567/ClashBar?style=flat-square&logo=github" />
  </a>
  <a href="https://github.com/mh567/ClashBar/releases" target="_blank" rel="noopener noreferrer">
    <img alt="Downloads" src="https://img.shields.io/github/downloads/mh567/ClashBar/total?style=flat-square&logo=github" />
  </a>
  <a href="https://github.com/mh567/ClashBar/commits" target="_blank" rel="noopener noreferrer">
    <img alt="Commit Activity" src="https://img.shields.io/github/commit-activity/m/mh567/ClashBar?style=flat-square&logo=github" />
  </a>
  <a href="https://github.com/mh567/ClashBar/commits" target="_blank" rel="noopener noreferrer">
    <img alt="Last Commit" src="https://img.shields.io/github/last-commit/mh567/ClashBar?style=flat-square&logo=github" />
  </a>
  <a href="https://github.com/mh567/ClashBar/blob/main/LICENSE" target="_blank" rel="noopener noreferrer">
    <img alt="License" src="https://img.shields.io/github/license/mh567/ClashBar?style=flat-square" />
  </a>
</p>

<p>
  📦 <a href="https://github.com/mh567/ClashBar/releases"><strong>Releases</strong></a>
  ·
  🧾 <a href="./CHANGELOG.md"><strong>更新日志</strong></a>
  ·
  🛠 <a href="./docs/MAINTENANCE.md"><strong>维护说明</strong></a>
</p>

</div>

<p>
  <img src="./docs/public/clashbar-black.png" width="49%" alt="ClashBar Dark" />
  <img src="./docs/public/clashbar-light.png" width="49%" alt="ClashBar Light" />
</p>

## ✨ 特点

- 🪶 **轻量**：去掉 Core 约 3 MB 内
- 🧭 **菜单栏优先**：配置导入/更新、节点切换、延迟测试、规则与连接排障
- 🔐 **系统集成**：系统代理、开机启动
- 📊 **可观测**：实时流量、连接、内存、日志过滤
- 🌍 **中英双语**：简体中文 / English

### 🔀 与上游的关系

本仓库是上游的 fork，使用独立的 `v1.x` 版本序列，安装包与应用内更新都来自本仓库 Releases；`brew install --cask clashbar` 安装的是上游版本。分支模型与发版流程见 [docs/MAINTENANCE.md](./docs/MAINTENANCE.md)。

### 📏 体积对比（macOS Finder 显示值，仅供参考）

| 客户端                 |     体积 |
| ---------------------- | -------: |
| ClashBar.app (No Core) |     3 MB |
| ClashMac.app           |  75.2 MB |
| Clash Verge.app        | 128.4 MB |
| Clash Party.app        | 496.7 MB |

## 📦 安装

**要求：** macOS 13+ 🍎

1. 打开 [本仓库 Releases](https://github.com/mh567/ClashBar/releases)，下载最新的 `.dmg`。
2. 把 `ClashBar.app` 拖入 `/Applications`。
3. 首次打开若被系统拦截，到「系统设置 → 隐私与安全性」中放行。

> [!NOTE]
> 本仓库的安装包使用 ad-hoc 签名，未做 Apple 公证。上游的 Homebrew tap
> （`brew install --cask clashbar`）安装的是上游版本，不会得到本仓库的构建，
> 应用内更新也不会跟踪到这里。

卸载：删除 `/Applications/ClashBar.app`，并清理 `~/Library/Application Support/clashbar`。
如果装过系统代理 Helper，删除 `/Library/PrivilegedHelperTools/com.clashbar.helper` 与
`/Library/LaunchDaemons/com.clashbar.helper.plist` 后重启即可。

> [!IMPORTANT]
>
> - ⚠️ 同一时间只让一个 mihomo / Clash 系客户端接管系统代理。
> - 📂 系统代理依赖打包后的 `.app`；请放到 `/Applications` 后再使用。
> - 🔑 第一次开启系统代理时输入管理员密码。helper 会装到系统目录，之后更新 app 不会让它失效。开机启动仍需在登录项中允许 ClashBar。
> - 🔄 系统代理开关异常时，在应用内重新打开一次；必要时 `Restart` 内核。若系统弹出后台项目提示，在登录项里允许该 helper。

## 🔄 版本与更新

- 本仓库从 `v1.0.0` 起使用独立版本序列，tag 为纯 `x.y.z`（可带 `v` 前缀）。
- 应用内的更新检查只读取本仓库的 Releases，「Latest」指本仓库的最新正式版。
- 升级前建议看 [CHANGELOG.md](./CHANGELOG.md) 对应小节；每个版本都注明安装包架构与签名情况。
- 目前正式发布的是 Apple Silicon 含 mihomo 内核的构建，其他变体可用本地脚本产出。

## 🚀 快速上手

1. 🖱️ 点击菜单栏图标打开面板
2. 📥 在 Proxy 选择或导入配置
3. ▶️ `Start` / `Restart` 启动内核
4. 🎛️ 选择模式：`Rule` / `Global` / `Direct`
5. 📶 切换节点并测速，确认可用后再开系统代理

> [!TIP]
> 分组测速会按配置解析地址：节点或子分组自己的 `url`、provider 的 `health-check.url` 优先，
> 未配置时回退父分组与默认地址；`DIRECT` 使用「设置 → 直连测试地址」，默认
> `http://connect.rom.miui.com/generate_204`。

## 📖 文档

- 文档站由上游部署：<https://clashbar.sitoi.workers.dev>，内容可能滞后于本仓库代码。
- 本仓库的维护、上游同步与发版说明：[docs/MAINTENANCE.md](./docs/MAINTENANCE.md)。
- 文档源码在 [`docs/`](./docs)，可用 `cd docs && pnpm dev` 本地预览。

## 🗺️ 功能一览

| 页面           | 内容                                            |
| -------------- | ----------------------------------------------- |
| 🧭 Proxy       | 配置、模式、系统代理、节点切换、延迟与 Provider |
| 📚 Rules       | 规则统计、筛选、Provider 更新                   |
| 🌐 Connections | 连接过滤与关闭                                  |
| 🪵 Logs        | 级别过滤、关键词检索                            |
| ⚙️ System      | 语言、状态栏、端口、`allow-lan` / `ipv6`、直连测试地址等 |

📁 运行时数据目录：`~/Library/Application Support/clashbar`  
🧩 内置内核会复制到：`~/Library/Application Support/clashbar/core/mihomo`

## 🛠️ 开发构建

```sh
# 依赖：Xcode / Swift 6.2+、macOS 13+
make build                 # 产出 dist/ClashBar.app（默认不含 Core）
make build WITH_CORE=1     # 打包内置 mihomo
make dist WITH_CORE=1      # app + dmg
make test                  # 运行 Swift 测试
make format                # swiftformat + swiftlint（需自行安装）
```

- 提交前至少跑通 `make build` 与 `make test`。
- 发布流程见 [docs/MAINTENANCE.md](./docs/MAINTENANCE.md)，本地发布使用 `Scripts/release_local.sh <tag>`。
- 文档站源码在 `docs/`，校验用 `cd docs && pnpm types:check`。

## 🙌 社区与反馈

- 🐛 本仓库的 Issue / PR：<https://github.com/mh567/ClashBar/issues>
- 💬 上游 Telegram 社区：<https://t.me/clashbars>（讨论内容以上游版本为主）
- 🌐 上游文档站：<https://clashbar.sitoi.workers.dev>

提交 Issue 时请附上 ClashBar 版本、macOS 版本、本机或远程内核状态，以及已脱敏的日志。
请勿上传订阅链接、密钥等私人信息。

## 👥 贡献者

[![Contributors](https://contrib.rocks/image?repo=mh567/ClashBar)](https://github.com/mh567/ClashBar/graphs/contributors)

## 🙏 致谢

- 感谢 [Sitoi/ClashBar](https://github.com/Sitoi/ClashBar) 提供上游项目，本仓库在其基础上维护。
- 感谢 [MetaCubeX/mihomo](https://github.com/MetaCubeX/mihomo) 提供内核能力。
- 感谢 [Linux DO](https://linux.do/) 社区的支持与帮助 🙏

## ⭐ Star 趋势

[![Star History Chart](https://star-history.dera.page/svg?repos=mh567/ClashBar&type=date&legend=top-left)](https://star-history.dera.page/#mh567/ClashBar&type=date&legend=top-left)
