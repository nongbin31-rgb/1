//
//  ProceduralStuccoTextureManager.swift
//  KedaOnlineReader
//
//  MangaPrism (漫棱) 细腻粉刷微粒与浮雕无缝纹理系统
//  特点：
//  1. 零素材外部依赖，运行时纯代码以 @3x 高精分辨率离屏生成透明底无缝切片；
//  2. 环形对角无缝衔接 (Toroidal Seamless Wrapping)，杜绝拼接网格缝隙；
//  3. 36 组柔和抹灰底晕 + 16,500 颗物理像素级超细微浮雕粉粒与纸浆微孔；
//  4. 配合内容空间相位对齐，滚动、翻页与缩放时微粒紧密贴合漫画纸面同步移动。
//

import CoreGraphics
import Foundation
import UIKit

public final class ProceduralStuccoTextureManager: @unchecked Sendable {
    public static let shared = ProceduralStuccoTextureManager()

    /// 逻辑点尺寸（pt），配合 tileScale = 3.0 生成 540×540 物理像素高精切片
    public static let tileSize: CGFloat = 180.0
    private static let tileScale: CGFloat = 3.0

    private var cachedTile: UIImage?
    private let lock = NSLock()
    private var isWarmingUp = false

    private init() {
        // 后台异步预热，避免首次打开阅读器时阻塞主线程
        warmUpAsync()
    }

    /// 异步预热纹理切片
    public func warmUpAsync() {
        guard cachedTile == nil && !isWarmingUp else { return }
        isWarmingUp = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            _ = self.getSharedTile()
            self.isWarmingUp = false
        }
    }

    /// 获取背景与纸面共用的全局唯一高精透明纹理（内存常驻）
    public func getSharedTile() -> UIImage {
        lock.lock()
        defer { lock.unlock() }

        if let cached = cachedTile {
            return cached
        }

        let tile = generateSharedTile()
        cachedTile = tile
        return tile
    }

    /// 计算非线性感知透明度（Gamma 0.78 校准，低档位温润细腻、高档位层次分明）
    public static func perceptualAlpha(for intensity: Double) -> Double {
        let clamped = max(0.0, min(1.0, intensity))
        return pow(clamped, 0.78)
    }

    // MARK: - 离屏生成 @3x 高精切片
    private func generateSharedTile() -> UIImage {
        let size = CGSize(width: Self.tileSize, height: Self.tileSize)
        let format = UIGraphicsImageRendererFormat()
        format.scale = Self.tileScale
        format.opaque = false

        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { context in
            let cg = context.cgContext

            // 保持透明底：纹理由纸浆底色与漫画原图共同作为底层，通过正片叠底自然融合
            paintSoftPlasterMarks(in: cg)
            paintEmbossedGrains(in: cg)
        }
    }

    // MARK: - 1. 低频柔和抹灰印记（Soft Plaster Marks）
    private func paintSoftPlasterMarks(in cg: CGContext) {
        var seed: UInt64 = 20261108
        func nextRandom() -> Double {
            seed = (seed &* 6364136223846793005) &+ 1442695040888963407
            return Double(seed >> 32) / Double(UInt32.max)
        }

        cg.saveGState()
        for _ in 0..<36 {
            let cx = nextRandom() * Self.tileSize
            let cy = nextRandom() * Self.tileSize
            let radius = 12.0 + nextRandom() * 14.0
            let isLight = nextRandom() > 0.5

            let color = isLight
                ? UIColor.white.withAlphaComponent(0.045).cgColor
                : UIColor.black.withAlphaComponent(0.014).cgColor

            cg.setFillColor(color)
            cg.setShadow(offset: .zero, blur: 6.0, color: color)
            drawSeamlessCircle(in: cg, cx: cx, cy: cy, radius: radius)
        }
        cg.restoreGState()
    }

    // MARK: - 2. 细腻微观浮雕粉粒与气孔（Fine Embossed Grains）
    private func paintEmbossedGrains(in cg: CGContext) {
        var seed: UInt64 = 20261109
        func nextRandom() -> Double {
            seed = (seed &* 6364136223846793005) &+ 1442695040888963407
            return Double(seed >> 32) / Double(UInt32.max)
        }

        cg.saveGState()
        // @3x 高精分辨率下开启抗锯齿，使 0.3~0.95pt 微粒柔滑自然，杜绝粗大锯齿噪点
        cg.setAllowsAntialiasing(true)
        cg.setShouldAntialias(true)

        let grainCount = 16500
        for _ in 0..<grainCount {
            let x = nextRandom() * Self.tileSize
            let y = nextRandom() * Self.tileSize

            // 12% 细腻视觉锚点微粒 (0.62~0.96pt)，88% 极细微粉粒 (0.30~0.58pt)
            let diameter: CGFloat = nextRandom() < 0.12
                ? CGFloat(0.62 + nextRandom() * 0.34)
                : CGFloat(0.30 + nextRandom() * 0.28)

            let isRaisedGrain = nextRandom() > 0.36

            if isRaisedGrain {
                // 浮雕微凸粒子：极细微右下角暗部偏置侧影 (0.32pt ≈ 1px @3x)
                if diameter > 0.52 {
                    let shadowAlpha = 0.055 + nextRandom() * 0.070
                    cg.setFillColor(UIColor.black.withAlphaComponent(shadowAlpha).cgColor)
                    drawSeamlessDot(
                        in: cg,
                        x: (x + 0.32).truncatingRemainder(dividingBy: Self.tileSize),
                        y: (y + 0.32).truncatingRemainder(dividingBy: Self.tileSize),
                        diameter: diameter * 0.85
                    )
                }

                // 纯白受光细微粒
                let highlightAlpha = 0.68 + nextRandom() * 0.22
                cg.setFillColor(UIColor.white.withAlphaComponent(highlightAlpha).cgColor)
                drawSeamlessDot(in: cg, x: x, y: y, diameter: diameter)
            } else {
                // 细腻凹陷微孔与纸浆微纤维 (Color 0xFF4C4E54)
                let poreAlpha = 0.065 + nextRandom() * 0.080
                let poreColor = UIColor(
                    red: CGFloat(0x4C) / 255.0,
                    green: CGFloat(0x4E) / 255.0,
                    blue: CGFloat(0x54) / 255.0,
                    alpha: CGFloat(poreAlpha)
                )
                cg.setFillColor(poreColor.cgColor)
                drawSeamlessDot(in: cg, x: x, y: y, diameter: diameter * 0.80)
            }
        }
        cg.restoreGState()
    }

    // MARK: - 3. 环形对角无缝平铺缝合（Toroidal Seamless Wrapping）
    private func drawSeamlessDot(in cg: CGContext, x: CGFloat, y: CGFloat, diameter: CGFloat) {
        let r = diameter / 2.0
        cg.fillEllipse(in: CGRect(x: x - r, y: y - r, width: diameter, height: diameter))

        let crossesLeft = x - r < 0
        let crossesRight = x + r > Self.tileSize
        let crossesTop = y - r < 0
        let crossesBottom = y + r > Self.tileSize

        if crossesLeft {
            cg.fillEllipse(in: CGRect(x: x + Self.tileSize - r, y: y - r, width: diameter, height: diameter))
        }
        if crossesRight {
            cg.fillEllipse(in: CGRect(x: x - Self.tileSize - r, y: y - r, width: diameter, height: diameter))
        }
        if crossesTop {
            cg.fillEllipse(in: CGRect(x: x - r, y: y + Self.tileSize - r, width: diameter, height: diameter))
        }
        if crossesBottom {
            cg.fillEllipse(in: CGRect(x: x - r, y: y - Self.tileSize - r, width: diameter, height: diameter))
        }

        if crossesLeft && crossesTop {
            cg.fillEllipse(in: CGRect(x: x + Self.tileSize - r, y: y + Self.tileSize - r, width: diameter, height: diameter))
        }
        if crossesLeft && crossesBottom {
            cg.fillEllipse(in: CGRect(x: x + Self.tileSize - r, y: y - Self.tileSize - r, width: diameter, height: diameter))
        }
        if crossesRight && crossesTop {
            cg.fillEllipse(in: CGRect(x: x - Self.tileSize - r, y: y + Self.tileSize - r, width: diameter, height: diameter))
        }
        if crossesRight && crossesBottom {
            cg.fillEllipse(in: CGRect(x: x - Self.tileSize - r, y: y - Self.tileSize - r, width: diameter, height: diameter))
        }
    }

    private func drawSeamlessCircle(in cg: CGContext, cx: CGFloat, cy: CGFloat, radius: CGFloat) {
        let d = radius * 2.0
        cg.fillEllipse(in: CGRect(x: cx - radius, y: cy - radius, width: d, height: d))

        let crossesLeft = cx - radius < 0
        let crossesRight = cx + radius > Self.tileSize
        let crossesTop = cy - radius < 0
        let crossesBottom = cy + radius > Self.tileSize

        if crossesLeft {
            cg.fillEllipse(in: CGRect(x: cx + Self.tileSize - radius, y: cy - radius, width: d, height: d))
        }
        if crossesRight {
            cg.fillEllipse(in: CGRect(x: cx - Self.tileSize - radius, y: cy - radius, width: d, height: d))
        }
        if crossesTop {
            cg.fillEllipse(in: CGRect(x: cx - radius, y: cy + Self.tileSize - radius, width: d, height: d))
        }
        if crossesBottom {
            cg.fillEllipse(in: CGRect(x: cx - radius, y: cy - Self.tileSize - radius, width: d, height: d))
        }

        if crossesLeft && crossesTop {
            cg.fillEllipse(in: CGRect(x: cx + Self.tileSize - radius, y: cy + Self.tileSize - radius, width: d, height: d))
        }
        if crossesLeft && crossesBottom {
            cg.fillEllipse(in: CGRect(x: cx + Self.tileSize - radius, y: cy - Self.tileSize - radius, width: d, height: d))
        }
        if crossesRight && crossesTop {
            cg.fillEllipse(in: CGRect(x: cx - Self.tileSize - radius, y: cy + Self.tileSize - radius, width: d, height: d))
        }
        if crossesRight && crossesBottom {
            cg.fillEllipse(in: CGRect(x: cx - Self.tileSize - radius, y: cy - Self.tileSize - radius, width: d, height: d))
        }
    }
}
