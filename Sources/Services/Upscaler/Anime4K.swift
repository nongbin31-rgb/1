// Copyright 2021 Yi Xie
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import Foundation
import Metal
import MetalKit
import UIKit

public final class Anime4K: @unchecked Sendable {
    #if targetEnvironment(macCatalyst)
    public static let bufferCount = 3
    #else
    public static let bufferCount = 2
    #endif

    public let name: String
    public let shaders: [MPVShader]
    public let libraries: [MTLLibrary]
    public let defaultLibrary: MTLLibrary?

    public var enabledShaders: [MPVShader] = []
    public var pipelineStates: [MTLComputePipelineState] = []
    public var finalResizePS: MTLComputePipelineState!
    public var textureMap: [[String: MTLTexture]] = []
    public var nearestSamplerStates: [MTLSamplerState] = []
    public var linearSamplerStates: [MTLSamplerState] = []
    public var sizeMap: [String: (Float, Float)] = [:]
    public var bufferIndex: Int = -1

    public var outputW: Float = 0
    public var outputH: Float = 0
    public var textureInW: Float = 0
    public var textureInH: Float = 0
    public var displayActualW: Float = 0
    public var displayActualH: Float = 0

    public init(_ name: String, subdir: String, device: MTLDevice) throws {
        self.name = name

        // 多路径自动探测 GLSL 着色器资源文件
        guard let glslFile = Self.locateShaderFile(name: name, subdir: subdir) else {
            throw Anime4KError.fileNotFound("\(subdir)/\(name)")
        }

        let data = try Data(contentsOf: glslFile)
        guard let glsl = String(data: data, encoding: .utf8) else {
            throw Anime4KError.fileCorrupt(name)
        }

        // 解析 MPV GLSL 多 Pass 定义
        self.shaders = try MPVShader.parse(glsl)

        // 动态将各 Pass 的 Metal 代码编译为 MTLLibrary
        self.libraries = try shaders.map { shader in
            try device.makeLibrary(source: shader.metalCode, options: nil)
        }

        // 加载包含 CenterResize 的 default.metallib，若不存在则回退动态编译
        let defLib = Self.loadDefaultLibrary(device: device)
        self.defaultLibrary = defLib
        if let fn = defLib?.makeFunction(name: "CenterResize"),
           let ps = try? device.makeComputePipelineState(function: fn) {
            self.finalResizePS = ps
        } else {
            // 内联编译标准双线性 CenterResize，保证 100% 存在
            self.finalResizePS = try Self.compileFallbackCenterResize(device: device)
        }
    }

    /// 根据输入尺寸、缩放目标尺寸求值 WHEN 条件，构建对应 Pass 的 GPU 计算管线
    public func compileShaders(
        _ device: MTLDevice,
        videoInW: Int,
        videoInH: Int,
        textureInW: Int,
        textureInH: Int,
        displayOutW: Int,
        displayOutH: Int
    ) throws {
        enabledShaders.removeAll()
        nearestSamplerStates.removeAll()
        linearSamplerStates.removeAll()
        pipelineStates.removeAll()
        textureMap.removeAll()
        sizeMap.removeAll()
        bufferIndex = -1

        self.textureInW = Float(textureInW)
        self.textureInH = Float(textureInH)
        let displayScale = min(Float(displayOutW) / Float(videoInW), Float(displayOutH) / Float(videoInH))
        displayActualW = round(displayScale * Float(videoInW))
        displayActualH = round(displayScale * Float(videoInH))
        self.outputW = self.textureInW
        self.outputH = self.textureInH

        sizeMap["MAIN"] = (Float(textureInW), Float(textureInH))
        sizeMap["NATIVE"] = (Float(videoInW), Float(videoInH))
        sizeMap["OUTPUT"] = (Float(displayActualW), Float(displayActualH))

        for i in 0..<shaders.count {
            let shader = shaders[i]

            // 基于逆波兰表达式求值 WHEN 动态旁路条件
            if let when = shader.when {
                let splits = when.split(separator: " ").compactMap { item -> Substring? in
                    if item == "WHEN" || item.isEmpty {
                        return nil
                    }
                    return item
                }
                var stack: [Float] = []
                for token in splits {
                    let tSplits = token.split(separator: ".")
                    if tSplits.count == 2 {
                        if tSplits[1] == "w" {
                            stack.append(sizeMap[String(tSplits[0])]?.0 ?? Float(textureInW))
                            continue
                        } else if tSplits[1] == "h" {
                            stack.append(sizeMap[String(tSplits[0])]?.1 ?? Float(textureInH))
                            continue
                        }
                    }
                    if ["+", "-", "*", "/", "<", ">"].contains(token) {
                        guard stack.count >= 2 else { break }
                        let rhs = stack.removeLast()
                        let lhs = stack.removeLast()
                        switch token {
                        case "+": stack.append(lhs + rhs)
                        case "-": stack.append(lhs - rhs)
                        case "*": stack.append(lhs * rhs)
                        case "/": stack.append(rhs != 0 ? lhs / rhs : 0)
                        case "<": stack.append(lhs < rhs ? 1 : 0)
                        case ">": stack.append(lhs > rhs ? 1 : 0)
                        default: break
                        }
                        continue
                    }
                    if let val = Float(token) {
                        stack.append(val)
                    }
                }
                if let result = stack.last, result == 0 {
                    continue
                }
            }

            enabledShaders.append(shader)
            let library = libraries[i]
            self.outputW = self.textureInW
            self.outputH = self.textureInH

            if let hooked = shader.hook {
                sizeMap["HOOKED"] = sizeMap[hooked]
            }
            if let widthMultiplier = shader.width {
                self.outputW = (sizeMap[widthMultiplier.0]?.0 ?? self.textureInW) * widthMultiplier.1
            }
            if let heightMultiplier = shader.height {
                self.outputH = (sizeMap[heightMultiplier.0]?.1 ?? self.textureInH) * heightMultiplier.1
            }
            if let save = shader.save, save != "MAIN" {
                sizeMap[save] = (self.outputW, self.outputH)
            }

            guard let fn = library.makeFunction(name: shader.functionName) else {
                throw Anime4KError.encoderFail("未能找到 Metal 计算入口: \(shader.functionName)")
            }
            let pipelineState = try device.makeComputePipelineState(function: fn)
            pipelineStates.append(pipelineState)
        }
    }

    /// 编码中间多 Pass 计算任务，返回生成的下一级纹理
    public func encode(_ device: MTLDevice, cmdBuf: MTLCommandBuffer, input: MTLTexture) throws -> MTLTexture {
        guard pipelineStates.count == enabledShaders.count else {
            throw Anime4KError.encoderFail("管线数量 \(pipelineStates.count) 与着色器数量 \(enabledShaders.count) 不一致")
        }
        if enabledShaders.isEmpty {
            return input
        }

        bufferIndex = (bufferIndex + 1) % Anime4K.bufferCount
        if textureMap.count <= bufferIndex {
            textureMap.append([:])
            let desc = MTLSamplerDescriptor()
            desc.magFilter = .nearest
            desc.minFilter = .nearest
            desc.sAddressMode = .clampToEdge
            desc.tAddressMode = .clampToEdge
            guard let nearestSampler = device.makeSamplerState(descriptor: desc) else {
                throw Anime4KError.encoderCreationFail("NearestSampler")
            }
            nearestSamplerStates.append(nearestSampler)

            desc.magFilter = .linear
            desc.minFilter = .linear
            guard let linearSampler = device.makeSamplerState(descriptor: desc) else {
                throw Anime4KError.encoderCreationFail("LinearSampler")
            }
            linearSamplerStates.append(linearSampler)
        }

        textureMap[bufferIndex]["MAIN"] = input
        textureMap[bufferIndex]["NATIVE"] = input

        let desc = MTLTextureDescriptor()
        desc.width = max(1, Int(outputW))
        desc.height = max(1, Int(outputH))
        desc.pixelFormat = .rgba16Float
        desc.usage = [.shaderWrite, .shaderRead]
        desc.storageMode = .private

        guard let outTex = device.makeTexture(descriptor: desc) else {
            throw Anime4KError.encoderCreationFail("OutputTexture")
        }
        textureMap[bufferIndex]["output"] = outTex

        for i in 0..<enabledShaders.count {
            let shader = enabledShaders[i]
            var passOutputW = textureInW
            var passOutputH = textureInH

            if let hooked = shader.hook {
                sizeMap["HOOKED"] = sizeMap[hooked]
            }
            if let widthMultiplier = shader.width {
                passOutputW = (sizeMap[widthMultiplier.0]?.0 ?? textureInW) * widthMultiplier.1
            }
            if let heightMultiplier = shader.height {
                passOutputH = (sizeMap[heightMultiplier.0]?.1 ?? textureInH) * heightMultiplier.1
            }

            guard let encoder = cmdBuf.makeComputeCommandEncoder() else {
                throw Anime4KError.encoderCreationFail(shader.functionName)
            }

            let pipelineState = pipelineStates[i]
            encoder.setComputePipelineState(pipelineState)

            if passOutputW >= textureInW {
                encoder.setSamplerState(nearestSamplerStates[bufferIndex], index: 0)
            } else {
                encoder.setSamplerState(linearSamplerStates[bufferIndex], index: 0)
            }

            for j in 0..<shader.inputTextureNames.count {
                var textureName = shader.inputTextureNames[j]
                if textureName == "HOOKED", let hook = shader.hook {
                    textureName = hook
                }
                if !textureMap[bufferIndex].keys.contains(textureName) {
                    if textureName == shader.save {
                        let tDesc = MTLTextureDescriptor()
                        tDesc.width = max(1, Int(passOutputW))
                        tDesc.height = max(1, Int(passOutputH))
                        tDesc.pixelFormat = .rgba16Float
                        tDesc.usage = [.shaderWrite, .shaderRead]
                        tDesc.storageMode = .private
                        guard let intermediate = device.makeTexture(descriptor: tDesc) else {
                            throw Anime4KError.encoderCreationFail(textureName)
                        }
                        textureMap[bufferIndex][textureName] = intermediate
                    } else {
                        throw Anime4KError.encoderFail("缺失纹理依赖: \(textureName)")
                    }
                }
                encoder.setTexture(textureMap[bufferIndex][textureName], index: j)
            }

            if shader.binds.contains(shader.outputTextureName) || !textureMap[bufferIndex].keys.contains(shader.outputTextureName) {
                let tDesc = MTLTextureDescriptor()
                tDesc.width = max(1, Int(passOutputW))
                tDesc.height = max(1, Int(passOutputH))
                tDesc.pixelFormat = .rgba16Float
                tDesc.usage = [.shaderWrite, .shaderRead]
                tDesc.storageMode = .private
                guard let intermediate = device.makeTexture(descriptor: tDesc) else {
                    throw Anime4KError.encoderCreationFail(shader.outputTextureName)
                }
                textureMap[bufferIndex][shader.outputTextureName] = intermediate
            }

            guard let outputTex = textureMap[bufferIndex][shader.outputTextureName] else {
                throw Anime4KError.encoderFail("未找到目标输出纹理: \(shader.outputTextureName)")
            }
            encoder.setTexture(outputTex, index: shader.inputTextureNames.count)

            let maxThreads = max(1, min(pipelineState.maxTotalThreadsPerThreadgroup, 256))
            let w = max(1, min(pipelineState.threadExecutionWidth, maxThreads))
            let h = max(1, maxThreads / w)
            let threadsPerThreadgroup = MTLSizeMake(w, h, 1)
            let threadgroupsPerGrid = MTLSize(
                width: (outputTex.width + w - 1) / w,
                height: (outputTex.height + h - 1) / h,
                depth: outputTex.arrayLength
            )
            encoder.dispatchThreadgroups(threadgroupsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)
            encoder.endEncoding()
        }

        // 安全获取最终输出纹理，杜绝强制解包闪退
        guard bufferIndex >= 0 && bufferIndex < textureMap.count else {
            return input
        }
        if let out = textureMap[bufferIndex]["output"] {
            return out
        }
        if let lastShader = enabledShaders.last, let out = textureMap[bufferIndex][lastShader.outputTextureName] {
            return out
        }
        return input
    }

    /// 仅编码最终 CenterResize，将上一阶段输出纹理写入目标 RGBA8 输出纹理
    public func encodeFinalResize(cmdBuf: MTLCommandBuffer, input: MTLTexture, output: MTLTexture) throws {
        guard let encoder = cmdBuf.makeComputeCommandEncoder() else {
            throw Anime4KError.encoderCreationFail("FinalResizeEncoder")
        }
        guard let finalPS = finalResizePS else {
            throw Anime4KError.encoderFail("缺失最终缩放着色器管线")
        }
        encoder.setComputePipelineState(finalPS)
        encoder.setTexture(input, index: 0)
        encoder.setTexture(output, index: 1)

        let maxThreads = max(1, min(finalPS.maxTotalThreadsPerThreadgroup, 256))
        let w = max(1, min(finalPS.threadExecutionWidth, maxThreads))
        let h = max(1, maxThreads / w)
        let threadsPerThreadgroup = MTLSizeMake(w, h, 1)
        let threadgroupsPerGrid = MTLSize(
            width: (output.width + w - 1) / w,
            height: (output.height + h - 1) / h,
            depth: output.arrayLength
        )
        encoder.dispatchThreadgroups(threadgroupsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)
        encoder.endEncoding()
    }

    /// 编码并将最终超分结果写入目标输出纹理
    public func encode(_ device: MTLDevice, cmdBuf: MTLCommandBuffer, input: MTLTexture, output: MTLTexture) throws {
        let outTex = try encode(device, cmdBuf: cmdBuf, input: input)
        try encodeFinalResize(cmdBuf: cmdBuf, input: outTex, output: output)
    }

    /// 释放本次推理产生的全部中间 GPU 纹理（保留已编译的 MTLLibrary 与着色器管线状态，大幅降低大图显存驻留）
    public func releaseIntermediateTextures() {
        textureMap.removeAll(keepingCapacity: false)
        nearestSamplerStates.removeAll(keepingCapacity: false)
        linearSamplerStates.removeAll(keepingCapacity: false)
        bufferIndex = -1
    }

    // MARK: - 静态文件与辅助加载

    private static func locateShaderFile(name: String, subdir: String) -> URL? {
        let cleanName = name.hasSuffix(".glsl") ? String(name.dropLast(5)) : name

        // 1. 在 "Anime4K_Shaders/" + subdir 目录下寻找
        if let url = Bundle.main.url(forResource: cleanName, withExtension: "glsl", subdirectory: "Anime4K_Shaders/" + subdir) {
            return url
        }
        if let url = Bundle.main.url(forResource: name, withExtension: nil, subdirectory: "Anime4K_Shaders/" + subdir) {
            return url
        }
        // 2. 在 "Anime4K_Shaders" 根目录寻找
        if let url = Bundle.main.url(forResource: cleanName, withExtension: "glsl", subdirectory: "Anime4K_Shaders") {
            return url
        }
        if let url = Bundle.main.url(forResource: name, withExtension: nil, subdirectory: "Anime4K_Shaders") {
            return url
        }
        // 3. 在 subdir 目录寻找
        if let url = Bundle.main.url(forResource: cleanName, withExtension: "glsl", subdirectory: subdir) {
            return url
        }
        if let url = Bundle.main.url(forResource: name, withExtension: nil, subdirectory: subdir) {
            return url
        }
        // 4. 在 Bundle 根目录寻找
        if let url = Bundle.main.url(forResource: cleanName, withExtension: "glsl") {
            return url
        }
        if let url = Bundle.main.url(forResource: name, withExtension: nil) {
            return url
        }
        // 5. Bundle.main.bundleURL 手动路径寻找
        let candidates = [
            Bundle.main.bundleURL.appendingPathComponent("Anime4K_Shaders/\(subdir)/\(name)"),
            Bundle.main.bundleURL.appendingPathComponent("Anime4K_Shaders/\(name)"),
            Bundle.main.bundleURL.appendingPathComponent("\(subdir)/\(name)"),
            Bundle.main.bundleURL.appendingPathComponent(name),
        ]
        for url in candidates {
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    private static func loadDefaultLibrary(device: MTLDevice) -> MTLLibrary? {
        // 内置 default.metallib 为 iOS 16+ (Metal 3.0) 目标预编译，iOS 15 直接跳过走内联回退编译，避免无效加载失败
        if #available(iOS 16.0, *) {
            if let url = Bundle.main.url(forResource: "default", withExtension: "metallib", subdirectory: "Anime4K_Shaders"),
               let lib = try? device.makeLibrary(URL: url) {
                return lib
            }
            if let url = Bundle.main.url(forResource: "default", withExtension: "metallib"),
               let lib = try? device.makeLibrary(URL: url) {
                return lib
            }
        }
        return device.makeDefaultLibrary()
    }

    private static func compileFallbackCenterResize(device: MTLDevice) throws -> MTLComputePipelineState {
        let source = """
        #include <metal_stdlib>
        using namespace metal;

        constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);

        kernel void CenterResize(
            texture2d<float, access::sample> input [[texture(0)]],
            texture2d<float, access::write> output [[texture(1)]],
            uint2 gid [[thread_position_in_grid]]
        ) {
            if (gid.x >= output.get_width() || gid.y >= output.get_height()) {
                return;
            }
            float inW = input.get_width();
            float inH = input.get_height();
            float outW = output.get_width();
            float outH = output.get_height();
            float scale = min(outW / inW, outH / inH);
            float outValidW = max(round(inW * scale), 1.0);
            float outValidH = max(round(inH * scale), 1.0);
            float outPadW = round((outW - outValidW) / 2);
            float outPadH = round((outH - outValidH) / 2);
            float2 nPos = float2((float(gid.x) - outPadW + 0.5) / outValidW, (float(gid.y) - outPadH + 0.5) / outValidH);
            if (nPos.x < 0.0 || nPos.x > 1.0 || nPos.y < 0.0 || nPos.y > 1.0) {
                output.write(float4(0.0, 0.0, 0.0, 1.0), gid);
                return;
            }
            float4 color = input.sample(linearSampler, nPos);
            color.a = 1.0;
            output.write(color, gid);
        }
        """
        let lib = try device.makeLibrary(source: source, options: nil)
        guard let fn = lib.makeFunction(name: "CenterResize") else {
            throw Anime4KError.encoderCreationFail("CenterResizeFunction")
        }
        return try device.makeComputePipelineState(function: fn)
    }
}

public enum Anime4KError: LocalizedError {
    case fileNotFound(String)
    case fileCorrupt(String)
    case encoderCreationFail(String)
    case encoderFail(String)

    public var errorDescription: String? {
        switch self {
        case let .fileNotFound(name):
            return "未找到 Anime4K 着色器文件: \(name)"
        case let .fileCorrupt(name):
            return "Anime4K 着色器文件损坏: \(name)"
        case let .encoderCreationFail(step):
            return "无法创建 Metal 编码器: \(step)"
        case let .encoderFail(step):
            return "Metal 编码失败: \(step)"
        }
    }
}
