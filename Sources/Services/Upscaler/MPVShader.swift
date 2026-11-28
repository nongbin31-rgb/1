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

public struct MPVShader: Sendable {
    public var name: String
    public var hook: String?
    public var binds: [String]
    public var save: String?
    public var components: Int?
    public var width: (String, Float)?
    public var height: (String, Float)?
    public var when: String?
    public var sigma: Double?
    public var code: [String]

    public var functionName: String {
        var fn = name
        fn.removeAll { ".-()".contains($0) }
        return fn
    }

    public var inputTextureNames: [String] {
        var names: [String] = binds
        if hook == "MAIN" && !binds.contains("MAIN") {
            names.append("MAIN")
        }
        return names
    }

    public var outputTextureName: String {
        if let save = save, save != "MAIN" {
            return save
        } else {
            return "output"
        }
    }

    public var metalCode: String {
        var header = """
        #include <metal_stdlib>
        using namespace metal;

        using vec2 = float2;
        using vec3 = float3;
        using vec4 = float4;
        using ivec2 = int2;
        using mat4 = float4x4;

        """

        var bindSizeIndex = 1
        binds.forEach { bind in
            bindSizeIndex += 1
            header += """
            #define \(bind)_pos mtlPos
            #define \(bind)_size float2(\(bind).get_width(), \(bind).get_height())
            #define \(bind)_pt (vec2(1, 1) / \(bind)_size)
            #define \(bind)_tex(pos) \(bind).sample(textureSampler, pos)
            #define \(bind)_texOff(off) \(bind)_tex(\(bind)_pos + \(bind)_pt * vec2(off))

            """
        }

        if hook == "MAIN" {
            header += """
            #define MAIN_pos mtlPos
            #define MAIN_pt (vec2(1, 1) / vec2(MAIN.get_width(), MAIN.get_height()))
            #define MAIN_size vec2(MAIN.get_width(), MAIN.get_height())
            #define MAIN_tex(pos) MAIN.sample(textureSampler, pos)
            #define MAIN_texOff(off) MAIN_tex(MAIN_pos + MAIN_pt * vec2(off))

            """
        }

        var extraArgs = "float2 mtlPos, sampler textureSampler, "
        var extraCallArgs = "mtlPos, textureSampler, "
        var entryArgs = ""
        for i in 0..<binds.count {
            extraArgs += "texture2d<float, access::sample> \(binds[i]), "
            extraCallArgs += "\(binds[i]), "
            entryArgs += "texture2d<float, access::sample> \(binds[i]) [[texture(\(i))]], "
        }

        var textureIdx = binds.count
        if hook == "MAIN" && !binds.contains("MAIN") {
            extraArgs += "texture2d<float, access::sample> MAIN, "
            extraCallArgs += "MAIN, "
            entryArgs += "texture2d<float, access::sample> MAIN [[texture(\(textureIdx))]], "
            textureIdx += 1
        }
        entryArgs += "texture2d<float, access::write> output [[texture(\(textureIdx))]], "
        entryArgs += "uint2 gid [[thread_position_in_grid]], "
        entryArgs += "sampler textureSampler [[sampler(0)]]"

        var functions: [String] = []
        var currentFunc: String? = nil
        var body = ""
        for line in code {
            if currentFunc == nil {
                let matches = MPVShader.matches(for: "(\\w*\\s+)(\\w+)\\((.*)\\)(\\s+\\{)", in: line)
                if matches.count == 5 {
                    let returnType = matches[1]
                    let name = matches[2]
                    let args = matches[3]
                    let suffix = matches[4]
                    currentFunc = name
                    functions.append(name)
                    var extra = extraArgs
                    if args.isEmpty {
                        extra.removeLast(2)
                    }
                    body += returnType + name + "(" + extra + args + ")" + suffix + "\n"
                    continue
                }
            } else {
                if line == "}" {
                    currentFunc = nil
                }
            }
            var newLine = line
            for function in functions {
                newLine = newLine.replacingOccurrences(of: function + "(", with: function + "(" + extraCallArgs)
                newLine = newLine.replacingOccurrences(of: ", )", with: ")")
            }
            body += newLine + "\n"
        }

        var hookCallArgs = extraCallArgs
        hookCallArgs.removeLast(2)
        // 归一化纹理坐标对齐 Metal 像素中心 (gid + 0.5) / size，消除半像素偏移引起的细线发虚
        body += """
        kernel void \(functionName)(\(entryArgs)) {
            if (gid.x >= output.get_width() || gid.y >= output.get_height()) {
                return;
            }
            float2 denom = max(float2(output.get_width(), output.get_height()), float2(1.0, 1.0));
            float2 mtlPos = (float2(gid) + float2(0.5, 0.5)) / denom;
            output.write(hook(\(hookCallArgs)), gid);
        }

        """
        return header + body
    }

    public init(_ name: String) {
        self.name = name
        self.binds = []
        self.code = []
    }

    public static func parse(_ glsl: String) throws -> [MPVShader] {
        var shaders: [MPVShader] = []
        var current: MPVShader? = nil

        let glslLines = glsl.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        for line in glslLines {
            if line.isEmpty {
                continue
            }
            if line.starts(with: "//") {
                if !line.starts(with: "//!") {
                    continue
                }
                var info = line
                info.removeFirst(3)
                let splitted = info.split(separator: " ").map { String($0) }
                switch splitted[0] {
                case "DESC":
                    if let cur = current {
                        shaders.append(cur)
                    }
                    current = MPVShader(splitted[1])
                case "HOOK":
                    current?.hook = splitted[1]
                    if current?.hook == "PREKERNEL" {
                        current?.hook = "MAIN"
                    }
                case "BIND":
                    current?.binds.append(splitted[1])
                case "SAVE":
                    current?.save = splitted[1]
                case "WIDTH":
                    if splitted.count == 4 {
                        if splitted[3] == "*" {
                            current?.width = (String(splitted[1].split(separator: ".")[0]), Float(splitted[2])!)
                        } else if splitted[3] == "/" {
                            current?.width = (String(splitted[1].split(separator: ".")[0]), 1.0 / Float(splitted[2])!)
                        } else {
                            throw GLSLError.parseFail(line)
                        }
                    } else if splitted.count == 2 {
                        current?.width = (String(splitted[1].split(separator: ".")[0]), 1)
                    }
                case "HEIGHT":
                    if splitted.count == 4 {
                        if splitted[3] == "*" {
                            current?.height = (String(splitted[1].split(separator: ".")[0]), Float(splitted[2])!)
                        } else if splitted[3] == "/" {
                            current?.height = (String(splitted[1].split(separator: ".")[0]), 1.0 / Float(splitted[2])!)
                        } else {
                            throw GLSLError.parseFail(line)
                        }
                    } else if splitted.count == 2 {
                        current?.height = (String(splitted[1].split(separator: ".")[0]), 1)
                    }
                case "COMPONENTS":
                    current?.components = Int(splitted[1])
                case "WHEN":
                    current?.when = info
                default:
                    throw GLSLError.parseFail(line)
                }
                continue
            }
            // 解决 "error: variable length arrays are not supported in Metal"
            if line.contains("#define SPATIAL_SIGMA") {
                let matches = matches(for: "#define SPATIAL_SIGMA (\\d+).*", in: line)
                if matches.count == 2, let val = Double(matches[1]) {
                    current?.sigma = val
                }
            }
            if line.contains("#define KERNELSIZE int(max(int(SPATIAL_SIGMA), 1) * 2 + 1)") {
                if let sigma = current?.sigma {
                    current?.code.append("#define KERNELSIZE " + String(Int(max(Int(sigma), 1) * 2 + 1)))
                    continue
                }
            }
            current?.code.append(line)
        }

        if let cur = current {
            shaders.append(cur)
        }

        return shaders
    }

    private static func matches(for regex: String, in text: String) -> [String] {
        do {
            let regex = try NSRegularExpression(pattern: regex)
            let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            return matches.flatMap { match in
                (0..<match.numberOfRanges).map {
                    let rangeBounds = match.range(at: $0)
                    guard let range = Range(rangeBounds, in: text) else {
                        return ""
                    }
                    return String(text[range])
                }
            }
        } catch {
            return []
        }
    }
}

public enum GLSLError: Error, LocalizedError {
    case parseFail(String)
    case shaderError(String)

    public var errorDescription: String? {
        switch self {
        case let .parseFail(msg):
            return "Anime4K 着色器语法解析失败: " + msg
        case let .shaderError(msg):
            return "Anime4K 着色器错误: " + msg
        }
    }
}
