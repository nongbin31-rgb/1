//
//  ProceduralStuccoTextureManager.swift
//  KedaOnlineReader
//
//  100% 完整复刻 DoveShelf / MangaPrism 粉刷微粒与双层高通微纤维纹理系统
//  特点：
//  1. 零素材外部依赖，运行时纯代码秒级离屏生成透明底无缝切片；
//  2. 环形对角无缝衔接 (Toroidal Seamless Wrapping)，杜绝拼接网格缝隙；
//  3. Stucco 抹灰批荡与立体砂砾引擎：42 处柔和抹刀印痕 + 23,500 颗微观浮雕砂砾与干燥微孔；
//  4. Paper Fiber 高频纸纤维同相双贴图引擎：9,600 条各向同性微纤维 + 环形高通滤波 +
//     微吸收贴图 (浅色微粒) 与零泛白柔光贴图 (彩图与中暗调立体质感)；
//  5. 屏幕空间绝对锁定与漫画内容空间相位对齐，滚动、翻页与缩放时无缝延展。
//

import CoreGraphics
import Foundation
import UIKit

public final class ProceduralStuccoTextureManager: @unchecked Sendable {
    public static let shared = ProceduralStuccoTextureManager()

    /// 贴图物理像素尺寸 (256×256 与 DoveShelf 保持一致)
    public static let tileSize: CGFloat = 256.0
    private static let tileIntSize: Int = 256

    private var cachedStuccoTile: UIImage?
    private var cachedFiberAbsorbTile: UIImage?
    private var cachedFiberSoftLightTile: UIImage?

    private let lock = NSLock()
    private var isWarmingUp = false

    private init() {
        // 后台异步并发预热，在进入阅读器前全部烘焙完毕
        warmUpAsync()
    }

    /// 异步预热三张核心贴图
    public func warmUpAsync() {
        guard (cachedStuccoTile == nil || cachedFiberAbsorbTile == nil) && !isWarmingUp else { return }
        isWarmingUp = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            _ = self.getStuccoTile()
            _ = self.getFiberTiles()
            self.lock.lock()
            self.isWarmingUp = false
            self.lock.unlock()
        }
    }

    // MARK: - 1. 贴图访问接口

    /// 获取粉刷批荡与 23,500 颗浮雕砂砾贴图 (向后兼容 getSharedTile)
    public func getSharedTile() -> UIImage {
        return getStuccoTile()
    }

    /// 获取粉刷批荡与立体浮雕砂砾贴图
    public func getStuccoTile() -> UIImage {
        lock.lock()
        defer { lock.unlock() }

        if let cached = cachedStuccoTile {
            return cached
        }

        let tile = generateStuccoTile()
        cachedStuccoTile = tile
        return tile
    }

    /// 获取纸纤维微吸收贴图 (用于浅色留白细腻颗粒)
    public func getFiberAbsorbTile() -> UIImage {
        return getFiberTiles().absorbTile
    }

    /// 获取纸纤维柔光贴图 (用于彩图与中间调立体纤维且零泛白)
    public func getFiberSoftLightTile() -> UIImage {
        return getFiberTiles().softLightTile
    }

    /// 一次性获取或生成同相纸纤维双贴图
    public func getFiberTiles() -> (absorbTile: UIImage, softLightTile: UIImage) {
        lock.lock()
        defer { lock.unlock() }

        if let absorb = cachedFiberAbsorbTile, let softLight = cachedFiberSoftLightTile {
            return (absorb, softLight)
        }

        let pair = generatePaperFiberPixelPair()
        cachedFiberAbsorbTile = pair.absorbTile
        cachedFiberSoftLightTile = pair.softLightTile
        return pair
    }

    // MARK: - 2. 感知强度校准曲线

    /// 纸张微粒感知强度曲线 (Gamma 0.72 校准，与 DoveShelf 完全对齐)
    public static func perceptualAlpha(for intensity: Double) -> Double {
        let clamped = max(0.0, min(1.0, intensity))
        return pow(clamped, 0.72)
    }

    /// 粉刷批荡底布感知强度曲线 (Gamma 0.66 校准，低档位也能呈现清脆浮雕微粒)
    public static func stuccoPerceptualAlpha(for intensity: Double) -> Double {
        let clamped = max(0.0, min(1.0, intensity))
        return pow(clamped, 0.66)
    }

    // MARK: - 3. Stucco 抹灰批荡与浮雕砂砾离屏生成 (256×256)

    private func generateStuccoTile() -> UIImage {
        let size = CGSize(width: Self.tileSize, height: Self.tileSize)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = false

        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { context in
            let cg = context.cgContext

            // 保持透明底：纹理由底色与漫画画页共同作为底层
            paintSoftPlasterMarks(in: cg)
            paintEmbossedGrains(in: cg)
        }
    }

    /// 42 处大尺度柔和粉刷批荡抹刀印痕 (带 10px 高斯模糊，微明暗起伏)
    private func paintSoftPlasterMarks(in cg: CGContext) {
        var random = DeterministicRandom(seed: 20261108)

        cg.saveGState()
        for _ in 0..<42 {
            let cx = random.nextDouble() * Double(Self.tileSize)
            let cy = random.nextDouble() * Double(Self.tileSize)
            let radius = 20.0 + random.nextDouble() * 38.0
            let isLight = random.nextBool()

            let color = isLight
                ? UIColor.white.withAlphaComponent(0.055)
                : UIColor.black.withAlphaComponent(0.020)

            cg.setFillColor(color.cgColor)
            cg.setShadow(offset: .zero, blur: 10.0, color: color.cgColor)
            drawSeamlessCircle(in: cg, cx: cx, cy: cy, radius: radius, size: Self.tileSize)
        }
        cg.restoreGState()
    }

    /// 23,500 颗带立体微观投影与纯白高光的浮雕砂砾 + 干燥气孔 (强制关闭抗锯齿，微粒锐利不发糊)
    private func paintEmbossedGrains(in cg: CGContext) {
        var random = DeterministicRandom(seed: 20261109)

        cg.saveGState()
        cg.setAllowsAntialiasing(false)
        cg.setShouldAntialias(false)

        let grainCount = 23500
        for _ in 0..<grainCount {
            let x = random.nextDouble() * Double(Self.tileSize)
            let y = random.nextDouble() * Double(Self.tileSize)

            // 16% 较大视觉锚点砂砾 (1.55~2.70px)，84% 细腻底砂 (0.75~1.80px)
            let diameter: Double = random.nextDouble() < 0.16
                ? (1.55 + random.nextDouble() * 1.15)
                : (0.75 + random.nextDouble() * 1.05)

            let isRaisedGrain = random.nextDouble() > 0.36

            if isRaisedGrain {
                // 凸起砂砾：在右下方 (x + 0.85, y + 0.85) 画偏置侧影
                if diameter > 0.95 {
                    let shadowAlpha = 0.10 + random.nextDouble() * 0.14
                    cg.setFillColor(UIColor.black.withAlphaComponent(shadowAlpha).cgColor)
                    drawSeamlessDot(
                        in: cg,
                        x: (x + 0.85).truncatingRemainder(dividingBy: Double(Self.tileSize)),
                        y: (y + 0.85).truncatingRemainder(dividingBy: Double(Self.tileSize)),
                        diameter: diameter * 0.88,
                        size: Self.tileSize
                    )
                }

                // 原位画纯白高光微粒
                let highlightAlpha = 0.82 + random.nextDouble() * 0.18
                cg.setFillColor(UIColor.white.withAlphaComponent(highlightAlpha).cgColor)
                drawSeamlessDot(in: cg, x: x, y: y, diameter: diameter, size: Self.tileSize)
            } else {
                // 微孔凹坑与纸浆微纤维 (Color 0xFF45474D)
                let poreAlpha = 0.12 + random.nextDouble() * 0.16
                let poreColor = UIColor(
                    red: 69.0 / 255.0,
                    green: 71.0 / 255.0,
                    blue: 77.0 / 255.0,
                    alpha: poreAlpha
                )
                cg.setFillColor(poreColor.cgColor)
                drawSeamlessDot(in: cg, x: x, y: y, diameter: diameter * 0.85, size: Self.tileSize)
            }
        }
        cg.restoreGState()
    }

    // MARK: - 4. Paper Fiber 高通纸纤维同相双贴图生成 (256×256)

    private func generatePaperFiberPixelPair() -> (absorbTile: UIImage, softLightTile: UIImage) {
        let size = Self.tileIntSize
        let mask = size - 1
        let total = size * size
        var random = DeterministicRandom(seed: 20261117)

        // 1. 零均值三角分布基础微噪，经环形高通滤波剥离大尺度斑块
        var rawNoise = [Double](repeating: 0.0, count: total)
        for i in 0..<total {
            rawNoise[i] = random.nextDouble() - random.nextDouble()
        }
        var hpNoise = highPassCircular(rawNoise, size: size, radius: 1, subtractWeight: 0.46)

        // 2. 9,600 条各向同性超细短纤维层 (1.6~3.4px) 双线性散布
        var fibers = [Double](repeating: 0.0, count: total)
        let fiberCount = 9600
        for _ in 0..<fiberCount {
            let x0 = random.nextDouble() * Double(size)
            let y0 = random.nextDouble() * Double(size)
            let angle = random.nextDouble() * (.pi * 2.0)
            let dx = cos(angle)
            let dy = sin(angle)
            let length = 1.6 + random.nextDouble() * 1.8
            let steps = max(1, Int(ceil(length * 2.0)))
            let polarity = (random.nextDouble() < 0.52) ? 1.0 : -0.90

            for s in 0...steps {
                let t = Double(s) / Double(steps)
                let px = x0 + dx * length * t
                let py = y0 + dy * length * t
                let ix0 = Int(floor(px))
                let iy0 = Int(floor(py))
                let fx = px - floor(px)
                let fy = py - floor(py)

                let x0w = ix0 & mask
                let x1w = (ix0 + 1) & mask
                let y0w = (iy0 & mask) * size
                let y1w = ((iy0 + 1) & mask) * size

                let taper = 1.0 - abs(t - 0.5) * 1.4
                let weight = polarity * taper * 0.25

                fibers[y0w + x0w] += weight * (1.0 - fx) * (1.0 - fy)
                fibers[y0w + x1w] += weight * fx * (1.0 - fy)
                fibers[y1w + x0w] += weight * (1.0 - fx) * fy
                fibers[y1w + x1w] += weight * fx * fy
            }
        }
        var hpFibers = highPassCircular(fibers, size: size, radius: 2, subtractWeight: 0.42)

        // 3. 归一化融合后同步生成同相双贴图
        normalizeZeroMeanUnitStd(&hpNoise)
        normalizeZeroMeanUnitStd(&hpFibers)

        var combined = [Double](repeating: 0.0, count: total)
        for i in 0..<total {
            combined[i] = 0.64 * hpNoise[i] + 0.36 * hpFibers[i]
        }
        normalizeZeroMeanUnitStd(&combined)

        let baseR: Double = 30.0
        let baseG: Double = 28.0
        let baseB: Double = 25.0

        var absorbPixels = [UInt8](repeating: 0, count: total * 4)
        var softLightPixels = [UInt8](repeating: 0, count: total * 4)

        for i in 0..<total {
            let v = combined[i]
            let off = i * 4

            // (A) 透明底微吸收贴图：浅色与留白处细腻颗粒
            let alphaNorm = max(0.0, min(0.34, 0.064 + 0.088 * v))
            let a = UInt8(clamping: Int(round(alphaNorm * 255.0)))
            absorbPixels[off + 0] = UInt8(clamping: Int(round((baseR * Double(a)) / 255.0)))
            absorbPixels[off + 1] = UInt8(clamping: Int(round((baseG * Double(a)) / 255.0)))
            absorbPixels[off + 2] = UInt8(clamping: Int(round((baseB * Double(a)) / 255.0)))
            absorbPixels[off + 3] = a

            // (B) 同相柔光贴图 (v > 0 压暗，v < 0 凸脊微亮；均值 <= 127 零泛白)
            let softLuma = UInt8(clamping: max(62, min(168, Int(round(127.0 - 48.0 * v)))))
            softLightPixels[off + 0] = softLuma
            softLightPixels[off + 1] = softLuma
            softLightPixels[off + 2] = softLuma
            softLightPixels[off + 3] = 255
        }

        let absorbImage = makeImageFromRGBA(pixels: absorbPixels, width: size, height: size)
            ?? UIImage()
        let softLightImage = makeImageFromRGBA(pixels: softLightPixels, width: size, height: size)
            ?? UIImage()

        return (absorbImage, softLightImage)
    }

    // MARK: - 5. 环形高通与像素合成辅助函数

    private func highPassCircular(_ src: [Double], size: Int, radius: Int, subtractWeight: Double) -> [Double] {
        let mask = size - 1
        let total = size * size
        let invWindow = 1.0 / Double(radius * 2 + 1)
        var horiz = [Double](repeating: 0.0, count: total)

        for y in 0..<size {
            let row = y * size
            for x in 0..<size {
                var sum = 0.0
                for d in -radius...radius {
                    sum += src[row + ((x + d) & mask)]
                }
                horiz[row + x] = sum * invWindow
            }
        }

        var out = [Double](repeating: 0.0, count: total)
        for y in 0..<size {
            let row = y * size
            for x in 0..<size {
                var sum = 0.0
                for d in -radius...radius {
                    sum += horiz[(((y + d) & mask) * size) + x]
                }
                out[row + x] = src[row + x] - subtractWeight * (sum * invWindow)
            }
        }
        return out
    }

    private func normalizeZeroMeanUnitStd(_ data: inout [Double]) {
        let len = data.count
        guard len > 0 else { return }
        var sum = 0.0
        for i in 0..<len {
            sum += data[i]
        }
        let mean = sum / Double(len)

        var sqSum = 0.0
        for i in 0..<len {
            let diff = data[i] - mean
            data[i] = diff
            sqSum += diff * diff
        }
        let std = sqrt(sqSum / Double(len))
        if std > 1e-8 {
            let invStd = 1.0 / std
            for i in 0..<len {
                data[i] *= invStd
            }
        }
    }

    private func makeImageFromRGBA(pixels: [UInt8], width: Int, height: Int) -> UIImage? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        let provider = CGDataProvider(data: Data(pixels) as CFData)
        guard let p = provider,
              let cg = CGImage(
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: width * 4,
                  space: colorSpace,
                  bitmapInfo: bitmapInfo,
                  provider: p,
                  decode: nil,
                  shouldInterpolate: false,
                  intent: .defaultIntent
              ) else {
            return nil
        }
        return UIImage(cgImage: cg)
    }

    // MARK: - 6. 环形对角无缝衔接缝合 (Toroidal Seamless Wrapping)

    private func drawSeamlessDot(in cg: CGContext, x: Double, y: Double, diameter: Double, size: CGFloat) {
        let r = diameter / 2.0
        let s = Double(size)
        cg.fillEllipse(in: CGRect(x: x - r, y: y - r, width: diameter, height: diameter))

        let crossesLeft = (x - r) < 0
        let crossesRight = (x + r) > s
        let crossesTop = (y - r) < 0
        let crossesBottom = (y + r) > s

        if crossesLeft {
            cg.fillEllipse(in: CGRect(x: x + s - r, y: y - r, width: diameter, height: diameter))
        }
        if crossesRight {
            cg.fillEllipse(in: CGRect(x: x - s - r, y: y - r, width: diameter, height: diameter))
        }
        if crossesTop {
            cg.fillEllipse(in: CGRect(x: x - r, y: y + s - r, width: diameter, height: diameter))
        }
        if crossesBottom {
            cg.fillEllipse(in: CGRect(x: x - r, y: y - s - r, width: diameter, height: diameter))
        }

        if crossesLeft && crossesTop {
            cg.fillEllipse(in: CGRect(x: x + s - r, y: y + s - r, width: diameter, height: diameter))
        }
        if crossesLeft && crossesBottom {
            cg.fillEllipse(in: CGRect(x: x + s - r, y: y - s - r, width: diameter, height: diameter))
        }
        if crossesRight && crossesTop {
            cg.fillEllipse(in: CGRect(x: x - s - r, y: y + s - r, width: diameter, height: diameter))
        }
        if crossesRight && crossesBottom {
            cg.fillEllipse(in: CGRect(x: x - s - r, y: y - s - r, width: diameter, height: diameter))
        }
    }

    private func drawSeamlessCircle(in cg: CGContext, cx: Double, cy: Double, radius: Double, size: CGFloat) {
        let d = radius * 2.0
        let s = Double(size)
        cg.fillEllipse(in: CGRect(x: cx - radius, y: cy - radius, width: d, height: d))

        let crossesLeft = (cx - radius) < 0
        let crossesRight = (cx + radius) > s
        let crossesTop = (cy - radius) < 0
        let crossesBottom = (cy + radius) > s

        if crossesLeft {
            cg.fillEllipse(in: CGRect(x: cx + s - radius, y: cy - radius, width: d, height: d))
        }
        if crossesRight {
            cg.fillEllipse(in: CGRect(x: cx - s - radius, y: cy - radius, width: d, height: d))
        }
        if crossesTop {
            cg.fillEllipse(in: CGRect(x: cx - radius, y: cy + s - radius, width: d, height: d))
        }
        if crossesBottom {
            cg.fillEllipse(in: CGRect(x: cx - radius, y: cy - s - radius, width: d, height: d))
        }

        if crossesLeft && crossesTop {
            cg.fillEllipse(in: CGRect(x: cx + s - radius, y: cy + s - radius, width: d, height: d))
        }
        if crossesLeft && crossesBottom {
            cg.fillEllipse(in: CGRect(x: cx + s - radius, y: cy - s - radius, width: d, height: d))
        }
        if crossesRight && crossesTop {
            cg.fillEllipse(in: CGRect(x: cx - s - radius, y: cy + s - radius, width: d, height: d))
        }
        if crossesRight && crossesBottom {
            cg.fillEllipse(in: CGRect(x: cx - s - radius, y: cy - s - radius, width: d, height: d))
        }
    }
}

// MARK: - 7. 确定性轻量 PRNG (xoroshiro128+，杜绝外部状态干扰)

private struct DeterministicRandom {
    private var s0: UInt64
    private var s1: UInt64

    init(seed: UInt64) {
        var smState = seed
        func nextSplitMix() -> UInt64 {
            smState &+= 0x9E3779B97F4A7C15
            var z = smState
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
        self.s0 = nextSplitMix()
        self.s1 = nextSplitMix()
        if s0 == 0 && s1 == 0 {
            s0 = 0x8A5CD789635D2DFF
            s1 = 0x121FD2155C472F96
        }
    }

    mutating func nextDouble() -> Double {
        let s0 = self.s0
        var s1 = self.s1
        let result = s0 &+ s1
        s1 ^= s0
        self.s0 = ((s0 << 24) | (s0 >> 40)) ^ s1 ^ (s1 << 16)
        self.s1 = (s1 << 37) | (s1 >> 27)
        return Double(result >> 11) * (1.0 / Double(1 &<< 53))
    }

    mutating func nextBool() -> Bool {
        return nextDouble() > 0.5
    }
}
