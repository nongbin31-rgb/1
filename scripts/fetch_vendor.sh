#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR_DIR="${ROOT_DIR}/Vendor"
TMP_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

echo "==> 准备官方开源超分依赖目录: ${VENDOR_DIR}"
rm -rf "${VENDOR_DIR}"
mkdir -p "${VENDOR_DIR}/Waifu2x" "${VENDOR_DIR}/Anime4KMetal" "${VENDOR_DIR}/Anime4K"

echo "==> [1/3] 拉取 imxieyi/waifu2x-ios (MIT)..."
git clone --depth 1 https://github.com/imxieyi/waifu2x-ios.git "${TMP_DIR}/waifu2x-ios"
cp -R "${TMP_DIR}/waifu2x-ios/waifu2x/"* "${VENDOR_DIR}/Waifu2x/"
# 移除原始 Info.plist 与 umbrella header，避免与 XcodeGen 生成的框架模块配置冲突
rm -f "${VENDOR_DIR}/Waifu2x/Info.plist" "${VENDOR_DIR}/Waifu2x/waifu2x.h"

# 补充 UIKit 导入，保证作为独立 Swift 5 Framework 编译无缺失符号
for f in "${VENDOR_DIR}/Waifu2x/UIImage+Alpha.swift" "${VENDOR_DIR}/Waifu2x/UIImage+Bicubic.swift"; do
  if [ -f "$f" ] && ! grep -q "import UIKit" "$f"; then
    python3 -c '
import sys
p = sys.argv[1]
txt = open(p, "r", encoding="utf-8").read()
txt = txt.replace("import Foundation", "import Foundation\nimport UIKit", 1)
open(p, "w", encoding="utf-8").write(txt)
' "$f"
  fi
done

# 仅保留 2x 超分所需 10 组模型（若需要 1x 仅降噪也可保留全部；此处保留全部以兼容 ModelFactory.swift 全部枚举）
echo "    Waifu2x 模型数量: $(ls "${VENDOR_DIR}/Waifu2x/models"/*.mlmodel | wc -l)"

echo "==> [2/3] 拉取 imxieyi/Anime4KMetal (Apache-2.0)..."
git clone --depth 1 https://github.com/imxieyi/Anime4KMetal.git "${TMP_DIR}/Anime4KMetal"
cp "${TMP_DIR}/Anime4KMetal/Shared/Anime4K.swift" "${VENDOR_DIR}/Anime4KMetal/"
cp "${TMP_DIR}/Anime4KMetal/Shared/MPVShader.swift" "${VENDOR_DIR}/Anime4KMetal/"
cp "${TMP_DIR}/Anime4KMetal/Shared/CenterResize.metal" "${VENDOR_DIR}/Anime4KMetal/"

echo "==> [3/3] 拉取 bloc97/Anime4K v4 GLSL 着色器 (MIT)..."
git clone --depth 1 https://github.com/bloc97/Anime4K.git "${TMP_DIR}/Anime4K"
cp -R "${TMP_DIR}/Anime4K/glsl" "${VENDOR_DIR}/Anime4K/glsl"

echo "==> 全部开源超分依赖准备完成！"
