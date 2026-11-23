#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ -d "${ROOT_DIR}/Frameworks/waifu2x.framework" ]; then
  echo "==> 检测到项目已内置waifu2x.framework 与 Anime4K 着色器资产，跳过外部 clone"
  exit 0
fi

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

# 加固 Queue.swift 与 Waifu2x.swift 在 iOS 16~18 / Swift 5 下的线程安全与防崩溃边界：
# 1) Queue.swift 增加 NSLock 防止多核 ARM64 生产者/消费者竞态
# 2) Waifu2x.swift 修复 normalize 对 NaN/Inf 的 UInt8 转换崩溃、兼容不同 MLMultiArrayDataType、消除 alpha_task 与 out_pipeline 对 imgData 的并发写冲突
python3 - <<PYEOF
import pathlib

queue_path = pathlib.Path("${VENDOR_DIR}/Waifu2x/Queue.swift")
queue_path.write_text("""import Foundation

class _QueueItem<T> {
    let value: T!
    var next: _QueueItem?

    init(_ newvalue: T?) {
        self.value = newvalue
    }
}

public class Queue<T> {
    private let lock = NSLock()
    var _front: _QueueItem<T>
    var _back: _QueueItem<T>

    public init() {
        _back = _QueueItem(nil)
        _front = _back
    }

    public func enqueue(_ value: T) {
        lock.lock()
        defer { lock.unlock() }
        _back.next = _QueueItem(value)
        _back = _back.next!
    }

    public func dequeue() -> T? {
        lock.lock()
        defer { lock.unlock() }
        if let newhead = _front.next {
            _front = newhead
            return newhead.value
        } else {
            return nil
        }
    }

    public func isEmpty() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return _front === _back
    }
}
""", encoding="utf-8")

waifu_path = pathlib.Path("${VENDOR_DIR}/Waifu2x/Waifu2x.swift")
wtxt = waifu_path.read_text(encoding="utf-8")

old_norm = """        let normalize = { (input: Double) -> Double in
            let output = input * 255
            if output > 255 {
                return 255
            }
            if output < 0 {
                return 0
            }
            return output
        }"""

new_norm = """        let normalize = { (input: Double) -> Double in
            let output = input * 255
            if !output.isFinite {
                return 0
            }
            if output > 255 {
                return 255
            }
            if output < 0 {
                return 0
            }
            return output
        }"""

assert old_norm in wtxt, "normalize block not found"
wtxt = wtxt.replace(old_norm, new_norm, 1)

# 将 alpha_task 写入 imgData 移至 out_pipeline.wait() 之后，避免 Swift Exclusivity 并发写冲突
old_alpha = """                for y in 0 ..< out_height {
                    for x in 0 ..< out_width {
                        imgData[(y * out_width + x) * channels + 3] = alpha[y * out_width + x]
                    }
                }
            }
        }
        // Output
        Waifu2x.out_pipeline = BackgroundPipeline<MLMultiArray>("out_pipeline", count: rects.count) { (index, array) in
            let rect = rects[index]
            let origin_x = Int(rect.origin.x) * out_scale
            let origin_y = Int(rect.origin.y) * out_scale
            let dataPointer = UnsafeMutableBufferPointer(start: array.dataPointer.assumingMemoryBound(to: Double.self),
                                                         count: bufferSize)
            var dest_x: Int
            var dest_y: Int
            var src_index: Int
            var dest_index: Int
            for channel in 0..<3 {
                for src_y in 0..<out_block_size {
                    for src_x in 0..<out_block_size {
                        dest_x = origin_x + src_x
                        dest_y = origin_y + src_y
                        src_index = src_y * out_block_size + src_x + out_block_size * out_block_size * channel
                        dest_index = (dest_y * out_width + dest_x) * channels + channel
                        imgData[dest_index] = UInt8(normalize(dataPointer[src_index]))
                    }
                }
            }
        }"""

new_alpha = """            }
        }
        // Output
        Waifu2x.out_pipeline = BackgroundPipeline<MLMultiArray>("out_pipeline", count: rects.count) { (index, array) in
            let rect = rects[index]
            let origin_x = Int(rect.origin.x) * out_scale
            let origin_y = Int(rect.origin.y) * out_scale
            let safeRead: (Int) -> Double = {
                switch array.dataType {
                case .double:
                    let ptr = array.dataPointer.assumingMemoryBound(to: Double.self)
                    return { idx in ptr[idx] }
                case .float32:
                    let ptr = array.dataPointer.assumingMemoryBound(to: Float.self)
                    return { idx in Double(ptr[idx]) }
                case .float16:
                    let ptr = array.dataPointer.assumingMemoryBound(to: UInt16.self)
                    return { idx in Double(Float(Float16(bitPattern: ptr[idx]))) }
                default:
                    let ptr = array.dataPointer.assumingMemoryBound(to: Double.self)
                    return { idx in ptr[idx] }
                }
            }()
            var dest_x: Int
            var dest_y: Int
            var src_index: Int
            var dest_index: Int
            for channel in 0..<3 {
                for src_y in 0..<out_block_size {
                    for src_x in 0..<out_block_size {
                        dest_x = origin_x + src_x
                        dest_y = origin_y + src_y
                        src_index = src_y * out_block_size + src_x + out_block_size * out_block_size * channel
                        dest_index = (dest_y * out_width + dest_x) * channels + channel
                        imgData[dest_index] = UInt8(normalize(safeRead(src_index)))
                    }
                }
            }
        }"""

assert old_alpha in wtxt, "out_pipeline block not found"
wtxt = wtxt.replace(old_alpha, new_alpha, 1)

old_wait = """        callback("wait_alpha")
        alpha_task?.wait()
        Waifu2x.out_pipeline.wait()"""

new_wait = """        Waifu2x.out_pipeline.wait()
        callback("wait_alpha")
        alpha_task?.wait()
        if hasalpha {
            for y in 0 ..< out_height {
                for x in 0 ..< out_width {
                    imgData[(y * out_width + x) * channels + 3] = alpha[y * out_width + x]
                }
            }
        }"""

assert old_wait in wtxt, "wait_alpha block not found"
wtxt = wtxt.replace(old_wait, new_wait, 1)

waifu_path.write_text(wtxt, encoding="utf-8")
print("Patched Queue.swift and Waifu2x.swift successfully")
PYEOF

echo "    Waifu2x 模型数量: $(ls "${VENDOR_DIR}/Waifu2x/models"/*.mlmodel | wc -l)"

echo "==> [2/3] 拉取 imxieyi/Anime4KMetal (Apache-2.0)..."
git clone --depth 1 https://github.com/imxieyi/Anime4KMetal.git "${TMP_DIR}/Anime4KMetal"
cp "${TMP_DIR}/Anime4KMetal/Shared/Anime4K.swift" "${VENDOR_DIR}/Anime4KMetal/"
cp "${TMP_DIR}/Anime4KMetal/Shared/MPVShader.swift" "${VENDOR_DIR}/Anime4KMetal/"
cp "${TMP_DIR}/Anime4KMetal/Shared/CenterResize.metal" "${VENDOR_DIR}/Anime4KMetal/"

# 标准 MSL 采样器在 iOS 16 Metal 编译器下不支持 filter::bicubic，替换为兼容性 100% 的 filter::linear
python3 -c '
p = "'"${VENDOR_DIR}/Anime4KMetal/CenterResize.metal"'"
txt = open(p, "r", encoding="utf-8").read()
txt = txt.replace("filter::bicubic", "filter::linear")
open(p, "w", encoding="utf-8").write(txt)
'

echo "==> [3/3] 拉取 bloc97/Anime4K v4 GLSL 着色器 (MIT)..."
git clone --depth 1 https://github.com/bloc97/Anime4K.git "${TMP_DIR}/Anime4K"
cp -R "${TMP_DIR}/Anime4K/glsl" "${VENDOR_DIR}/Anime4K/glsl"

echo "==> 全部开源超分依赖准备完成！"
