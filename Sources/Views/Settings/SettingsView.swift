import SwiftUI

/// 全局设置页（默认超分管线、缓存管理、开源许可说明）
public struct SettingsView: View {
    @EnvironmentObject private var store: AppStore

    @State private var cacheSizeText = "计算中..."
    @State private var showingClearAlert = false

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("默认超分引擎", selection: $store.upscalerConfig.engine) {
                        ForEach(UpscalerEngine.allCases) { engine in
                            Text(engine.displayName).tag(engine)
                        }
                    }

                    if store.upscalerConfig.engine == .anime4k {
                        Picker("Anime4K 预设", selection: $store.upscalerConfig.anime4k.preset) {
                            ForEach(Anime4kPreset.allCases) { preset in
                                Text(preset.displayName).tag(preset)
                            }
                        }
                        Toggle("细化线稿 (Thin_HQ)", isOn: $store.upscalerConfig.anime4k.thinLines)
                        Toggle("加深线稿 (Darken_HQ)", isOn: $store.upscalerConfig.anime4k.darkenLines)
                    } else if store.upscalerConfig.engine == .waifu2x {
                        Picker("Waifu2x 模型", selection: $store.upscalerConfig.waifu2x) {
                            ForEach(Waifu2xModelPreset.allCases) { preset in
                                Text(preset.displayName).tag(preset)
                            }
                        }
                    }
                } header: {
                    Text("默认图像超分辨率")
                } footer: {
                    Text("安全边界：Waifu2x 自动限制输入尺寸 200px~2500px；Anime4K 自动限制最大边 ≤ 2500px，超出范围自动回退原图以防 OOM。")
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

                Section("关于与开源致谢") {
                    LabeledContent("应用定位", value: "纯原生 iOS 在线漫画阅读器")
                    LabeledContent("最低系统", value: "iOS 16.0")
                    LabeledContent("Waifu2x 引擎", value: "imxieyi/waifu2x-ios (MIT)")
                    LabeledContent("Anime4K Metal", value: "imxieyi/Anime4KMetal (Apache-2.0)")
                    LabeledContent("Anime4K 着色器", value: "bloc97/Anime4K v4 (MIT)")
                }
            }
            .navigationTitle("设置")
            .task {
                await refreshCacheSize()
            }
            .alert("确认清理缓存？", isPresented: $showingClearAlert) {
                Button("取消", role: .cancel) {}
                Button("清理", role: .destructive) {
                    Task {
                        await OnlineImageLoader.shared.clearAllCache()
                        PageUpscalerPipeline.shared.clearCache()
                        await Anime4kService.shared.clearPipelineCache()
                        await refreshCacheSize()
                    }
                }
            } message: {
                Text("将清空已下载的在线漫画缓存图片以及 Metal/超分内存缓存。")
            }
        }
    }

    private func refreshCacheSize() async {
        let bytes = await OnlineImageLoader.shared.diskCacheSizeBytes()
        cacheSizeText = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
