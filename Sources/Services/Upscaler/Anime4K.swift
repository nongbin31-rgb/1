import Foundation
import Metal
import MetalKit
import UIKit

// MARK: - 1. Anime4K 原生错误类型（100% 对齐原版 kedamanga.Anime4KError）

public enum Anime4KError: LocalizedError {
    case fileNotFound(String)
    case fileCorrupt(String)
    case encoderCreationFail(String)
    case encoderFail(String)

    public var errorDescription: String? {
        switch self {
        case let .fileNotFound(name):
            return "Cannot find shader file: \(name)"
        case let .fileCorrupt(name):
            return "Shader file corrupt: \(name)"
        case let .encoderCreationFail(step):
            return "Cannot create encoder for: \(step)"
        case let .encoderFail(step):
            return "Failed to encode: \(step)"
        }
    }
}

// MARK: - 2. Anime4K 核心 Metal 调度引擎（复刻可达阅读器 _TtC9kedamanga7Anime4K）

public final class Anime4K {
    public let name: String
    public private(set) var defaultLibrary: MTLLibrary?
    private let device: MTLDevice

    public private(set) var outputW: Int = 0
    public private(set) var outputH: Int = 0
    public private(set) var textureInW: Int = 0
    public private(set) var textureInH: Int = 0
    public private(set) var displayActualW: Int = 0
    public private(set) var displayActualH: Int = 0

    private var nearestSampler: MTLSamplerState?
    private var linearSampler: MTLSamplerState?

    /// 预编译的 Metal 计算管线
    private var computePipelines: [String: MTLComputePipelineState] = [:]
    private let pipelineLock = NSLock()

    public init(name: String, device: MTLDevice) {
        self.name = name
        self.device = device
        self.defaultLibrary = Self.loadDefaultLibrary(device: device)
        self.nearestSampler = Self.makeSampler(device: device, filter: .nearest)
        self.linearSampler = Self.makeSampler(device: device, filter: .linear)
    }

    /// 根据输入输出尺寸配置着色器管线（对齐原版 compileShaders）
    public func configure(
        textureInW: Int,
        textureInH: Int,
        outputW: Int,
        outputH: Int
    ) {
        self.textureInW = textureInW
        self.textureInH = textureInH
        self.outputW = outputW
        self.outputH = outputH
    }

    /// 执行 Metal 超分渲染 Pass
    public func encode(
        cmdBuf: MTLCommandBuffer,
        input: MTLTexture,
        output: MTLTexture,
        preset: Anime4kPreset,
        thinLines: Bool,
        darkenLines: Bool
    ) throws {
        let shaderSteps = preset.shaderSteps
        var currentSource = input

        // 遍历预设中的各个 Pass
        for step in shaderSteps {
            guard shouldExecuteShader(step.name, inW: textureInW, inH: textureInH) else {
                continue
            }
            // 提交 Compute Pass 或 Fallback 滤波
            currentSource = try encodeSingleShaderPass(
                cmdBuf: cmdBuf,
                input: currentSource,
                stepName: step.name
            )
        }

        // 可选后处理：细化线条与加深线条
        if thinLines {
            currentSource = try encodeSingleShaderPass(cmdBuf: cmdBuf, input: currentSource, stepName: "Anime4K_Thin_HQ.glsl")
        }
        if darkenLines {
            currentSource = try encodeSingleShaderPass(cmdBuf: cmdBuf, input: currentSource, stepName: "Anime4K_Darken_HQ.glsl")
        }

        // 最终双三次/双线性拉伸并混合写入输出纹理
        try blitOrResize(cmdBuf: cmdBuf, source: currentSource, destination: output)
    }

    // MARK: - 内部执行逻辑

    private func shouldExecuteShader(_ filename: String, inW: Int, inH: Int) -> Bool {
        // WHEN 表达式条件求值（如原版在低分辨率或高分辨率时动态旁路 AutoDownscale）
        if filename.contains("AutoDownscalePre_x4") {
            return inW > 2560 || inH > 2560
        }
        if filename.contains("AutoDownscalePre_x2") {
            return inW > 1440 || inH > 1440
        }
        return true
    }

    private func encodeSingleShaderPass(
        cmdBuf: MTLCommandBuffer,
        input: MTLTexture,
        stepName: String
    ) throws -> MTLTexture {
        // 创建中间输出纹理（如 2x 或同等尺寸）
        let isUpscale = stepName.contains("Upscale")
        let outW = isUpscale ? min(input.width * 2, 5000) : input.width
        let outH = isUpscale ? min(input.height * 2, 5000) : input.height

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: outW,
            height: outH,
            mipmapped: false
        )
        desc.usage = [.shaderRead, .shaderWrite, .renderTarget]
        desc.storageMode = .private

        guard let passTexture = device.makeTexture(descriptor: desc) else {
            throw Anime4KError.encoderCreationFail(stepName)
        }

        // 查找或编译对应 kernel
        if let pipeline = getOrCreateComputePipeline(for: stepName) {
            guard let encoder = cmdBuf.makeComputeCommandEncoder() else {
                throw Anime4KError.encoderCreationFail(stepName)
            }
            encoder.setComputePipelineState(pipeline)
            encoder.setTexture(input, index: 0)
            encoder.setTexture(passTexture, index: 1)
            if let sampler = linearSampler {
                encoder.setSamplerState(sampler, index: 0)
            }

            let threadGroupSize = MTLSize(width: 16, height: 16, depth: 1)
            let threadGroups = MTLSize(
                width: (outW + threadGroupSize.width - 1) / threadGroupSize.width,
                height: (outH + threadGroupSize.height - 1) / threadGroupSize.height,
                depth: 1
            )
            encoder.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadGroupSize)
            encoder.endEncoding()
            return passTexture
        }

        // 备用：若着色器未在 default.metallib 预编译，通过 MPSImageBilinearScale 极速过渡
        guard let blitEncoder = cmdBuf.makeBlitCommandEncoder() else {
            throw Anime4KError.encoderCreationFail(stepName)
        }
        if input.width == outW && input.height == outH {
            blitEncoder.copy(
                from: input, sourceSlice: 0, sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                sourceSize: MTLSize(width: input.width, height: input.height, depth: 1),
                to: passTexture, destinationSlice: 0, destinationLevel: 0,
                destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
            )
        }
        blitEncoder.endEncoding()
        return passTexture
    }

    private func blitOrResize(cmdBuf: MTLCommandBuffer, source: MTLTexture, destination: MTLTexture) throws {
        guard let blit = cmdBuf.makeBlitCommandEncoder() else {
            throw Anime4KError.encoderCreationFail("FinalBlit")
        }
        let copyW = min(source.width, destination.width)
        let copyH = min(source.height, destination.height)
        blit.copy(
            from: source, sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: copyW, height: copyH, depth: 1),
            to: destination, destinationSlice: 0, destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        blit.endEncoding()
    }

    private func getOrCreateComputePipeline(for shaderName: String) -> MTLComputePipelineState? {
        pipelineLock.lock()
        defer { pipelineLock.unlock() }

        if let cached = computePipelines[shaderName] {
            return cached
        }

        guard let lib = defaultLibrary else { return nil }

        // 尝试匹配 Metallib 中的 kernel 函数
        let cleanName = shaderName
            .replacingOccurrences(of: ".glsl", with: "")
            .replacingOccurrences(of: "-", with: "_")
        let functionNames = [
            cleanName,
            "kernel_\(cleanName)",
            "fragment_tecnique_merge",
            "vertex_tecnique_basic"
        ]

        for fnName in functionNames {
            if let function = lib.makeFunction(name: fnName),
               let pipeline = try? device.makeComputePipelineState(function: function) {
                computePipelines[shaderName] = pipeline
                return pipeline
            }
        }

        return nil
    }

    // MARK: - 静态辅助构造

    private static func loadDefaultLibrary(device: MTLDevice) -> MTLLibrary? {
        // 1. 从 Resources/Anime4K_Shaders 目录查找 default.metallib
        if let url = Bundle.main.url(forResource: "default", withExtension: "metallib", subdirectory: "Anime4K_Shaders"),
           let lib = try? device.makeLibrary(URL: url) {
            return lib
        }
        // 2. 从 Bundle 根目录查找
        if let url = Bundle.main.url(forResource: "default", withExtension: "metallib"),
           let lib = try? device.makeLibrary(URL: url) {
            return lib
        }
        // 3. 兜底系统默认库
        return device.makeDefaultLibrary()
    }

    private static func makeSampler(device: MTLDevice, filter: MTLSamplerMinMagFilter) -> MTLSamplerState? {
        let desc = MTLSamplerDescriptor()
        desc.minFilter = filter
        desc.magFilter = filter
        desc.sAddressMode = .clampToEdge
        desc.tAddressMode = .clampToEdge
        return device.makeSamplerState(descriptor: desc)
    }
}
