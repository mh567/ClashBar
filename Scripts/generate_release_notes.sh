#!/usr/bin/env bash

set -euo pipefail

if [[ $# -lt 2 || $# -gt 3 ]]; then
  echo "Usage: $0 <tag> <version> [output_path]" >&2
  exit 1
fi

tag="$1"
version="$2"
output_path="${3:-release.md}"
changelog_path="CHANGELOG.md"

if [[ ! -f "$changelog_path" ]]; then
  echo "Missing $changelog_path" >&2
  exit 1
fi

changelog_section="$(
  python3 - "$changelog_path" "$version" <<'PY'
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
version = sys.argv[2]
text = path.read_text(encoding="utf-8")
pattern = re.compile(
    rf"^##\s+v?{re.escape(version)}\s*$\n(.*?)(?=^##\s+|\Z)",
    re.MULTILINE | re.DOTALL,
)
match = pattern.search(text)
if not match:
    sys.exit(1)
section = match.group(1).strip()
sys.stdout.write(section)
PY
)" || {
  echo "Failed to find release notes for version ${version} in ${changelog_path}" >&2
  exit 1
}

repo_url="https://github.com/${GITHUB_REPOSITORY}"
download_base="${repo_url}/releases/download/${tag}"

# Artifacts actually produced by the release workflow's build matrix. Keep this
# in sync with the matrix in .github/workflows/release-dmg.yml: listing a variant
# here that is not built yields a dead download link.
RELEASE_VARIANTS="${RELEASE_VARIANTS:-apple-silicon}"

labels_for_variant() {
  case "$1" in
    apple-silicon | apple-silicon-no-core)
      printf 'Apple Silicon|Apple_Silicon|M系列芯片|0071E3|apple'
      ;;
    intel | intel-no-core)
      printf 'Intel|Intel|x86__64|0071C5|intel'
      ;;
    *)
      printf ''
      ;;
  esac
}

download_table() {
  local row_variants=" $RELEASE_VARIANTS "
  local arch variant labels

  for arch in apple-silicon intel; do
    local core_link="" nocore_link=""
    local label="" badge_name="" badge_value="" badge_color="" logo=""

    for variant in "${arch}" "${arch}-no-core"; do
      labels="$(labels_for_variant "$variant")"
      [ -n "$labels" ] || continue

      case "$row_variants" in
        *" $variant "*)
          if [ "$variant" = "$arch" ]; then
            core_link="[ClashBar-${version}-${variant}.dmg](${download_base}/ClashBar-${version}-${variant}.dmg)"
          else
            nocore_link="[ClashBar-${version}-${variant}.dmg](${download_base}/ClashBar-${version}-${variant}.dmg)"
          fi
          ;;
      esac
    done

    [ -n "$core_link$nocore_link" ] || continue

    IFS='|' read -r label badge_name badge_value badge_color logo <<< "$(labels_for_variant "$arch")"
    printf '| ![%s](https://img.shields.io/badge/%s-%s-%s?style=flat-square&logo=%s&logoColor=white) | %s | %s |\n' \
      "$label" "$badge_name" "$badge_value" "$badge_color" "$logo" \
      "${core_link:-—}" "${nocore_link:-—}"
  done
}

cat >"$output_path" <<EOF
## 更新内容

${changelog_section}

### 📥 下载地址 (Downloads)

请根据您的 Mac 处理器芯片选择对应的版本下载（普通用户建议下载带有 **[内置内核]** 的版本）：

| 🖥 平台架构 (Architecture) | 📦 内置 Mihomo 内核 (默认推荐) | 🛠️ 无内核纯净版 (适合高阶用户) |
| :--- | :--- | :--- |
$(download_table)

EOF
