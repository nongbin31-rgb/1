import SwiftUI

/// 全局设置页（默认超分管线、翻页特效、缓存管理、开源许可说明）
public struct SettingsView: View {
    @EnvironmentObject private var store: AppStore

    @State private var cacheSizeText = "计算中..."
    @State private var showingClearAlert = false

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("启用 AI 画质增强（会有额外功耗）", isOn: $store.enableImageUpscaler)

                    if store.enableImageUpscaler {
                        Picker("预设模式 (引擎)", selection: $store.upscalerConfig.model) {
                            ForEach(ImageUpscalerModel.allCases) { model in
                                Text(model.displayName).tag(model)
                            }
                        }
                        .pickerStyle(.segmented)

                        if store.upscalerConfig.model == .anime4k {
                            Picker("Anime4K 预设模式", selection: $store.upscalerConfig.anime4k.preset) {
                                ForEach(Anime4kPreset.allCases) { preset in
                                    Text(preset.displayName).tag(preset)
                                }
                            }
                            Toggle("细化线条 (Anime4K_Thin_HQ)", isOn: $store.upscalerConfig.anime4k.thinLines)
                            Toggle("线条加黑 (Anime4K_Darken_HQ)", isOn: $store.upscalerConfig.anime4k.darkenLines)
                        } else if store.upscalerConfig.model == .waifu2x {
                            Picker("Waifu2x 预设模型", selection: $store.upscalerConfig.waifu2x) {
                                ForEach(Waifu2xModel.allCases) { model in
                                    Text(model.displayName).tag(model)
                                }
                            }
                        }

                        Toggle("增强后平滑淡入", isOn: $store.transitionAfterImageUpscaled)
                    }
                } header: {
                    Text("画质增强 - 全局配置")
                } footer: {
                    Text("目前仅会增强宽高均在 2500px 内的图像，超过该大小画质增强的意义不大。")
                }

                Section("阅读排版与翻页特效") {
                    Picker("默认排版方式", selection: $store.readerLayoutMode) {
                        ForEach(ReaderLayoutMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }

                    Picker("默认左右翻页特效", selection: $store.pageTurningEffect) {
                        ForEach(PageTurningEffect.allCases) { effect in
                            Text(effect.displayName).tag(effect)
                        }
                    }

                    Toggle("翻页音效与轻触震动", isOn: $store.pageTurnSoundEnabled)
                    Toggle("仿真卷页书脊立体中缝阴影", isOn: $store.showSpineShadowInCurl)
                }

                Section("阅读背景与拟真纸质") {
                    Picker("默认背景模式", selection: $store.preferredReaderBackground) {
                        ForEach(ReaderBackground.allCases) { mode in
                            Label(mode.title, systemImage: mode.systemIcon).tag(mode)
                        }
                    }

                    if store.preferredReaderBackground == .texture {
                        Picker("默认纸张材质", selection: $store.readerTextureType) {
                            ForEach(ReaderTextureType.allCases) { item in
                                Text(item.displayName).tag(item)
                            }
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("纸质透光与纤维浓度")
                                Spacer()
                                Text("\(Int(store.readerTextureOpacity * 100))%")
                                    .foregroundStyle(.secondary)
                            }
                            Slider(
                                value: $store.readerTextureOpacity,
                                in: 0.1...1.0,
                                step: 0.05
                            )
                        }
                    }

                    Toggle("书脊中缝立体阴影", isOn: $store.showSpineShadowInCurl)
                    Toggle("书脊中缝细分割线", isOn: $store.showSpineDividingLine)
                }

                Section("存储与显存缓存") {
                    HStack {
                        Text("在线图片磁盘缓存")
                        Spacer()
                        Text(cacheSizeText)
                            .foregroundStyle(.secondary)
                    }

                    Button(role: .destructive) {
                        showingClearAlert = true
                    } label: {
                        Text("清理全部图片与超分管线缓存")
                    }
                }

                Section("关于与技术架构") {
                    LabeledContent("应用定位", value: "纯原生 iOS 在线漫画阅读器")
                    LabeledContent("最低系统", value: "iOS 16.0")
                    LabeledContent("超分资产包", value: "可达阅读器_1.7.2 原包提取 (18 模型 + 48 GLSL)")
                    LabeledContent("Waifu2x 核心", value: "Apple Neural Engine (ANE) Float16 编译模型")
                    LabeledContent("Anime4K 引擎", value: "Metal 多 Pass 实时计算着色器")
                    LabeledContent("拟真背景引擎", value: "6 套实体纸张扫描材质 + 正片叠底复合管线")
                }
            }
            .navigationTitle("设置")
            .task {
                await refreshCacheSize()
            }
            .alert("清理缓存", isPresented: $showingClearAlert) {
                Button("取消", role: .cancel) {}
                Button("清空", role: .destructive) {
                    Task {
                        await OnlineImageLoader.shared.clearAllCache()
                        PageUpscalerPipeline.shared.clearCache()
                        await refreshCacheSize()
                    }
                }
            } message: {
                Text("将清空所有已下载章节图片与近期生成的 2x 高清超分位图，释放设备存储空间。")
            }
        }
    }

    private func refreshCacheSize() async {
        let bytes = await OnlineImageLoader.shared.diskCacheSizeBytes()
        let mb = Double(bytes) / 1024.0 / 1024.0
        cacheSizeText = String(format: "%.1f MB", mb)
    }
}
