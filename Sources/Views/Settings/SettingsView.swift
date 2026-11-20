import SwiftUI

/// 全局设置页（默认超分管线、翻页特效、缓存管理、开源许可说明）
public struct SettingsView: View {
    @EnvironmentObject private var store: AppStore

    @State private var cacheSizeText = "计算中..."
    @State private var showingClearAlert = false

    public var body: some View {
        NavigationView {
            Form {
                Section {
                    HStack(spacing: 16) {
                        Image("AppLogo")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 64, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .shadow(color: .black.opacity(0.12), radius: 6, x: 0, y: 3)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("清阅在线漫画")
                                .font(.headline.weight(.bold))
                            Text("版本 1.0.0 · 双核 AI 超分引擎")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }

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
                        Toggle("解除超分尺寸限制（慎用）", isOn: $store.upscalerConfig.bypassSizeLimit)
                    }
                } header: {
                    Text("画质增强 - 全局配置")
                } footer: {
                    if store.upscalerConfig.bypassSizeLimit {
                        Text("已解除 1200 万总像素限制，所有尺寸图像都会尝试 2x 超分。极端巨图可能导致内存飙升或闪退；Anime4K 仍受 Metal 单边 8192px 硬件上限约束。")
                    } else {
                        Text("默认采用 1200 万总像素智能保护（放行 800×8000 等模糊条漫长图，同时防爆内存）；Anime4K 单边受 Metal 硬件 8192px 上限约束。")
                    }
                }

                Section("图源浏览与分页模式") {
                    Picker("发现页默认浏览模式", selection: $store.discoverPaginationMode) {
                        ForEach(DiscoverPaginationMode.allCases) { mode in
                            Label(mode.displayName, systemImage: mode.iconName).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    Toggle("智能排版 (韩漫条漫 / 日漫翻页)", isOn: $store.autoDetectMangaLayout)

                    Picker(store.autoDetectMangaLayout ? "未识别漫画排版" : "默认排版方式", selection: $store.readerLayoutMode) {
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
                } header: {
                    Text("阅读排版与翻页特效")
                } footer: {
                    if store.autoDetectMangaLayout {
                        Text("已开启智能排版：遇到韩漫/Webtoon 自动切换为长图无限滚动（条漫），遇到日漫自动切换为从右向左日漫翻页；亦可在阅读器中为每部漫画单独指定。")
                    } else {
                        Text("已关闭智能排版：所有漫画统一采用上方指定的默认排版方式。")
                    }
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

                        Picker("纹理作用目标", selection: $store.readerTextureTarget) {
                            ForEach(ReaderTextureTarget.allCases) { target in
                                Label(target.displayName, systemImage: target.systemIcon).tag(target)
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

                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("纸张着色浓度")
                                Spacer()
                                Text("\(Int((store.readerTextureTintOpacity * 100).rounded()))%")
                                    .foregroundStyle(.secondary)
                            }
                            Slider(
                                value: $store.readerTextureTintOpacity,
                                in: 0.0...1.0,
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
                    CompatLabeledContent("应用定位", value: "纯原生 iOS 在线漫画阅读器")
                    CompatLabeledContent("最低系统", value: "iOS 15.0")
                    CompatLabeledContent("超分资产包", value: "可达阅读器_1.7.2 原包提取 (18 模型 + 48 GLSL)")
                    CompatLabeledContent("Waifu2x 核心", value: "Apple Neural Engine (ANE) Float16 编译模型")
                    CompatLabeledContent("Anime4K 引擎", value: "Metal 多 Pass 实时计算着色器")
                    CompatLabeledContent("拟真背景引擎", value: "6 套实体纸张扫描材质 + 正片叠底复合管线")
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
        .navigationViewStyle(.stack)
    }

    private func refreshCacheSize() async {
        let bytes = await OnlineImageLoader.shared.diskCacheSizeBytes()
        let mb = Double(bytes) / 1024.0 / 1024.0
        cacheSizeText = String(format: "%.1f MB", mb)
    }
}
