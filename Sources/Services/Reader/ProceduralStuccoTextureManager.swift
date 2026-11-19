//
//  ProceduralStuccoTextureManager.swift
//  KedaOnlineReader
//
//  复刻自 MangaPrism (漫棱) 独家粉刷微粒与浮雕无缝纹理系统
//  特点：
//  1. 零素材外部依赖，运行时纯代码生成 256x256 高精透明底切片；
//  2. 环形对角无缝衔接 (Toroidal Seamless Wrapping)，杜绝拼接网格缝隙；
//  3. 42 组低频抹灰厚度起伏 + 23,500 颗高频立体浮雕砂粒与纤维孔隙；
//  4. 屏幕空间相位锁定 (Screen-Space Phase Lock)，翻页、滚动、缩放时微粒纹理绝对锚定。
//

import CoreGraphics
import Foundation
import UIKit

public final class ProceduralStuccoTextureManager: @unchecked Sendable {
    public static let shared = ProceduralStuccoTextureManager()

    public static let tileSize: CGFloat = 256.0

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

    /// 计算非线性感知透明度（Gamma 0.66 校准，低档位保留清晰骨架，避免变成灰雾）
    public static func perceptualAlpha(for intensity: Double) -> Double {
        let clamped = max(0.0, min(1.0, intensity))
        return pow(clamped, 0.66)
    }

    // MARK: - 离屏生成切片
    private func generateSharedTile() -> UIImage {
        let size = CGSize(width: Self.tileSize, height: Self.tileSize)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0 // 1:1 物理像素离屏绘制
        format.opaque = false

        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { context in
            let cg = context.cgContext

            // 保持透明底：纹理由背景底色与漫画原图共同作为底层，同一份微粒自然穿透两条绘制链
            paintSoftPlasterMarks(in: cg)
            paintEmbossedGrains(in: cg)
        }
    }

    // MARK: - 1. 低频柔和抹灰印记（Soft Plaster Marks）
    private func paintSoftPlasterMarks(in cg: CGContext) {
        // 固定伪随机数发生器（对齐 MangaPrism 20261108 种子）
        var seed: UInt64 = 20261108
        func nextRandom() -> Double {
            seed = (seed &* 6364136223846793005) &+ 1442695040888963407
            return Double(seed >> 32) / Double(UInt32.max)
        }

        cg.saveGState()
        for _ in 0..<42 {
            let cx = nextRandom() * Self.tileSize
            let cy = nextRandom() * Self.tileSize
            let radius = 20.0 + nextRandom() * 38.0
            let isLight = nextRandom() > 0.5

            let color = isLight
                ? UIColor.white.withAlphaComponent(0.055).cgColor
                : UIColor.black.withAlphaComponent(0.020).cgColor

            cg.setFillColor(color)
            // 羽化微晕模拟
            cg.setShadow(offset: .zero, blur: 10.0, color: color)
            drawSeamlessCircle(in: cg, cx: cx, cy: cy, radius: radius)
        }
        cg.restoreGState()
    }

    // MARK: - 2. 微观浮雕颗粒与气孔（Embossed Grains）
    private func paintEmbossedGrains(in cg: CGContext) {
        // 固定伪随机数发生器（对齐 MangaPrism 20261109 种子）
        var seed: UInt64 = 20261109
        func nextRandom() -> Double {
            seed = (seed &* 6364136223846793005) &+ 1442695040888963407
            return Double(seed >> 32) / Double(UInt32.max)
        }

        cg.saveGState()
        // 关键点：禁用抗锯齿以让微细微粒保持晶体颗粒的硬度与骨架，防止被模糊均化
        cg.setAllowsAntialiasing(false)

        let grainCount = 23500
        for _ in 0..<grainCount {
            let x = nextRandom() * Self.tileSize
            let y = nextRandom() * Self.tileSize

            // 16% 为大颗粒作为视觉锚点，84% 为高频极细砂
            let diameter: CGFloat = nextRandom() < 0.16
                ? CGFloat(1.55 + nextRandom() * 1.15)
                : CGFloat(0.75 + nextRandom() * 1.05)

            let isRaisedGrain = nextRandom() > 0.36

            if isRaisedGrain {
                // 浮雕微凸粒子：较大颗粒在右下角 (x+0.85, y+0.85) 产生暗部偏置微阴影
                if diameter > 0.95 {
                    let shadowAlpha = 0.10 + nextRandom() * 0.14
                    cg.setFillColor(UIColor.black.withAlphaComponent(shadowAlpha).cgColor)
                    drawSeamlessDot(
                        in: cg,
                        x: (x + 0.85).truncatingRemainder(dividingBy: Self.tileSize),
                        y: (y + 0.85).truncatingRemainder(dividingBy: Self.tileSize),
                        diameter: diameter * 0.88
                    )
                }

                // 纯白受光微粒
                let highlightAlpha = 0.82 + nextRandom() * 0.18
                cg.setFillColor(UIColor.white.withAlphaComponent(highlightAlpha).cgColor)
                drawSeamlessDot(in: cg, x: x, y: y, diameter: diameter)
            } else {
                // 凹陷气孔与纸浆纤维微杂质 (Color 0xFF45474D)
                let poreAlpha = 0.12 + nextRandom() * 0.16
                let poreColor = UIColor(
                    red: CGFloat(0x45) / 255.0,
                    green: CGFloat(0x47) / 255.0,
                    blue: CGFloat(0x4D) / 255.0,
                    alpha: CGFloat(poreAlpha)
                )
                cg.setFillColor(poreColor.cgColor)
                drawSeamlessDot(in: cg, x: x, y: y, diameter: diameter * 0.85)
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

        // 顶角同时跨越
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
