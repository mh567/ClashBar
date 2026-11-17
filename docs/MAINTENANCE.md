# 维护说明（fork）

本仓库是 [Sitoi/ClashBar](https://github.com/Sitoi/ClashBar) 的 fork，通过
`mh567/ClashBar` 发布自己的构建。本文说明分支模型、上游同步与分家流程。

## 分支模型

```
upstream/main ──► main（上游 + 可回流修复）──► fork/*（本仓库特有改动）
                  origin/main
```

- **`main`**：跟踪上游的可回流修复集合。上面只放上游也会认可的改动（bug 修复、测试、
  工程改进），以便随时回到「上游 + 小补丁」的状态。
- **`fork/*`**：与上游必然冲突的改动（仓库标识、发布流程、特有功能）。这些不合并回
  `main`，因为每次同步上游都要在本文件里重放冲突。
- **`origin/main`**：对外发布分支，始终等于本地 `main`。

这个划分的目的是让 `main` 与 `upstream/main` 的差异始终很小。差异越小，同步越便宜。

## 同步上游

```sh
git fetch upstream
Scripts/sync_upstream.sh --check   # 只看差异，不改动
Scripts/sync_upstream.sh           # 快进或 rebase 到 upstream/main
git push origin main
```

脚本行为：

- `main` 没有本地提交时用 `--ff-only` 快进，历史保持线性。
- `main` 有本地提交时改用 `rebase`，把你的修复重放到上游最新之上。
- 有未提交改动或不在 `main` 上时直接拒绝，避免半途状态。

`git pull upstream` 不要用。`pull` 会引入 merge 提交，让后续 rebase 变复杂。

同步后务必跑 `make test`。上游改动与你补丁的交互只能靠测试发现。

## 修上游 bug 的流程

1. 从 `main` 开分支，写修复和回归测试。
2. 合回 `main`，同步时靠 rebase 保持在上游之上。
3. 上游合入等效修复后，本地提交会在 rebase 时变成空提交，`git rebase` 会自动丢弃，
   `main` 自动回到纯上游状态。这是这套模型最大的好处。

## 本仓库特有改动（`fork/*`）

与上游必然冲突的改动只存在于 `fork/*` 分支，不合入 `main`。这类改动通常包括：
仓库标识与更新检查地址、文档站链接、以及发布流程中仅上游有权执行的步骤。

具体清单见对应 `fork/*` 分支的提交说明，`main` 上不维护该清单，以免与上游冲突。

## 发版

从 `v1.0.0` 起使用独立版本序列，与上游的 `0.3.x` 分开，避免 tag 重名。
必须是纯 `x.y.z`（可带 `v` 前缀）：带其他前缀（如 `fork-v1.0.0`）会让
`AppSemanticVersion` 解析失败，应用内的更新检查会失效。

### 本地发布（推荐）

CI 需要为每个产物占用一台 macOS runner，免费账户配额有限，容易排队超时。
本地发布走同一套脚本，由本机直接产出并上传：

```sh
git checkout fork/personal        # 发布分支，含仓库标识改动
git tag -a v1.1.0 -m "ClashBar v1.1.0"
git push origin v1.1.0
Scripts/release_local.sh v1.1.0    # 构建 → 校验 → 创建或追加 Release
```

- 工作区必须干净，且 tag 已存在，保证产物与 tag 对应。
- `--draft` 只构建不发布；`--no-core` 产出无内核版；`--arch` 仅用于交叉编译。
- 发布前先在 `CHANGELOG.md` 顶部补对应版本小节，否则发布说明生成会失败。

### CI 发布

`release-dmg.yml` 由 tag 触发。构建矩阵当前只保留 arm64 含 Core 单产物以
节省配额；恢复其他变体时要同步修改 `Scripts/generate_release_notes.sh` 的
`RELEASE_VARIANTS`，否则下载表格会链接到未构建的文件。

### 分发说明

产物为 ad-hoc 签名，未做 notarization。用户首次打开需要在「系统设置 →
隐私与安全性」中放行。bundle id 与上游一致（`com.clashbar`），因此不能与
上游版本同时安装，两者会共用数据目录与特权 Helper。

## 分家（不再跟随上游）

```sh
git branch archive/upstream-merged main   # 留个记号
git remote remove upstream
```

之后 `main` 成为唯一主线，`fork/*` 的内容按需合入。历史不需要重写。

若届时仍要发布，需要确认 `AppReleaseSource` 与文档链接已全部指向本仓库，
否则用户会被引导去安装上游版本。

## 提交身份

仓库未固定 `user.name` / `user.email`，提交会使用主机名推断的身份。若要规范：

```sh
git config user.name "你的名字"
git config user.email "你的 GitHub 邮箱"
```
