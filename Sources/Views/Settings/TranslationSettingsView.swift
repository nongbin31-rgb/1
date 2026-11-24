import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// 漫画翻译设置页（支持「设置」二级推入，也支持阅读器内模态 Sheet 快速弹出）
public struct TranslationSettingsView: View {
    public var embeddedInNavigation: Bool = true
    public var onDismiss: (() -> Void)? = nil

    @ObservedObject private var manager = MangaTranslationManager.shared
    @State private var revealAPIKey = false
    @State private var isTestingConnection = false
    @State private var testStatusOK: Bool? = nil
    @State private var testStatusMessage: String? = nil
    @State private var showingClearCacheAlert = false

    public init(
        embeddedInNavigation: Bool = true,
        onDismiss: (() -> Void)? = nil
    ) {
        self.embeddedInNavigation = embeddedInNavigation
        self.onDismiss = onDismiss
    }

    public var body: some View {
        if embeddedInNavigation {
            formContent
                .navigationTitle("漫画翻译")
                .navigationBarTitleDisplayMode(.inline)
                .compatNavigationBarHidden(false)
        } else {
            CompatNavigationContainer {
                formContent
                    .navigationTitle("漫画翻译")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button("完成") {
                                onDismiss?()
                            }
                            .font(.subheadline.weight(.semibold))
                        }
                    }
            }
        }
    }

    private var formContent: some View {
        Form {
            activeEngineStatusSection
            engineAndLanguageSection
            aiConfigurationSection
            behaviorAndCacheSection
        }
        .onAppear {
            manager.refreshDiskCacheCount()
        }
        .alert("清空翻译缓存？", isPresented: $showingClearCacheAlert) {
            Button("取消", role: .cancel) {}
            Button("清空", role: .destructive) {
                manager.clearAllCache()
            }
        } message: {
            Text("将删除所有已缓存的译文气泡数据，下次翻译对应页面时会重新请求。")
        }
    }

    // MARK: - Sections

    private var activeEngineStatusSection: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: manager.config.resolvedEffectiveEngine == .aiLLM ? "sparkles" : "character.bubble.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 36, height: 36)
                    .background(
                        manager.config.resolvedEffectiveEngine == .aiLLM ? Color.purple : Color.accentColor,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )

                VStack(alignment: .leading, spacing: 3) {
                    Text("当前生效：\(manager.config.activeEngineSummary)")
                        .font(.subheadline.weight(.semibold))
                    Text(activeEngineSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)
        } header: {
            Text("当前状态")
        }
    }

    private var activeEngineSubtitle: String {
        switch manager.config.resolvedEffectiveEngine {
        case .aiLLM:
            return manager.config.useVLMMode
                ? "直接将页面发给视觉大模型识字并结合画面意译"
                : "本地 Apple Vision OCR 识字 + AI 上下文意译（更快更省额度）"
        case .appleOffline:
            return "未配置 AI Key 时默认使用苹果系统离线翻译，完全免费、免 Key"
        case .bingFree:
            return "免 Key 免费在线翻译（国内直连可用）"
        case .googleFree:
            return "免 Key 免费在线翻译（需支持访问 Google 网络环境）"
        case .auto:
            return "根据系统版本与 API Key 自动选择最佳引擎"
        }
    }

    private var engineAndLanguageSection: some View {
        Section {
            Picker("翻译引擎", selection: $manager.config.engine) {
                ForEach(MangaTranslationEngine.allCases) { engine in
                    Text(engine.displayName).tag(engine)
                }
            }

            Picker("漫画原文语言", selection: $manager.config.sourceLanguage) {
                ForEach(MangaTranslationSourceLanguage.allCases) { lang in
                    Text(lang.displayName).tag(lang)
                }
            }
        } header: {
            Text("引擎与语言")
        } footer: {
            Text("选择「智能默认」时：填入 AI Key 后自动走 AI 翻译；未填 Key 时，iOS 18+ 自动走 Apple 免费离线翻译，iOS 15~17 自动走 Bing 免费翻译。")
        }
    }

    private var aiConfigurationSection: some View {
        Section {
            Picker("AI 服务商", selection: Binding(
                get: { manager.config.aiProvider },
                set: { newProvider in
                    let oldDefaultModel = manager.config.aiProvider.defaultModelName
                    manager.config.aiProvider = newProvider
                    if manager.config.modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || manager.config.modelName == oldDefaultModel {
                        manager.config.modelName = newProvider.defaultModelName
                    }
                    if newProvider != .custom {
                        manager.config.customBaseURL = ""
                    }
                    testStatusOK = nil
                    testStatusMessage = nil
                }
            )) {
                ForEach(MangaTranslationAIProvider.allCases) { provider in
                    Text(provider.displayName).tag(provider)
                }
            }

            // API Key 输入栏 + 一键粘贴 + 显隐切换
            HStack(spacing: 8) {
                Group {
                    if revealAPIKey {
                        TextField("粘贴 API Key（可留空使用免费引擎）", text: $manager.config.apiKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    } else {
                        SecureField("粘贴 API Key（可留空使用免费引擎）", text: $manager.config.apiKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }
                .font(.subheadline)

                #if canImport(UIKit)
                Button {
                    if let pasted = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !pasted.isEmpty {
                        manager.config.apiKey = pasted
                        testStatusOK = nil
                        testStatusMessage = nil
                    }
                } label: {
                    Text("粘贴")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.accentColor.opacity(0.14), in: Capsule())
                }
                .buttonStyle(.plain)
                #endif

                Button {
                    revealAPIKey.toggle()
                } label: {
                    Image(systemName: revealAPIKey ? "eye.slash" : "eye")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            if manager.config.aiProvider == .custom {
                TextField("Base URL（如 https://api.openai.com/v1）", text: $manager.config.customBaseURL)
                    .font(.subheadline)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("模型名称")
                        .font(.subheadline)
                    Spacer()
                    TextField("模型 ID", text: $manager.config.modelName)
                        .font(.subheadline)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                // 快捷模型推荐标签
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(manager.config.aiProvider.suggestedModels, id: \.self) { suggested in
                            let isSelected = manager.config.resolvedModelName == suggested
                            Button {
                                manager.config.modelName = suggested
                            } label: {
                                Text(suggested)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(isSelected ? Color.white : Color.primary)
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 4)
                                    .background(
                                        isSelected ? Color.accentColor : Color(uiColor: .secondarySystemFill),
                                        in: Capsule()
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            Toggle("视觉直译模式（VLM 识图）", isOn: $manager.config.useVLMMode)

            Button {
                runConnectionTest()
            } label: {
                HStack {
                    Label("测试 AI 连接", systemImage: "bolt.horizontal.circle")
                    Spacer()
                    if isTestingConnection {
                        ProgressView()
                    }
                }
            }
            .disabled(isTestingConnection || !manager.config.hasConfiguredAIKey)

            if let msg = testStatusMessage, let ok = testStatusOK {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(ok ? Color.green : Color.orange)
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(ok ? Color.primary : Color.orange)
                }
            }
        } header: {
            Text("AI 大模型配置（可选）")
        } footer: {
            Text("\(manager.config.aiProvider.keyHelpHint)\n默认关闭「视觉直译模式」，优先使用 Apple Vision OCR + AI 文本翻译（速度更快、最省免费额度）；遇到手写字或艺术字多的作品时可开启 VLM（需 Gemini / 视觉模型支持）。")
        }
    }

    private var behaviorAndCacheSection: some View {
        Section {
            Toggle("自动跟随翻页翻译（预翻下一页）", isOn: $manager.config.autoFollowPages)

            HStack {
                Text("已缓存译文页数")
                Spacer()
                Text("\(manager.cachedDiskPageCount) 页")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            if manager.cachedDiskPageCount > 0 {
                Button(role: .destructive) {
                    showingClearCacheAlert = true
                } label: {
                    Text("清空本地翻译缓存")
                }
            }
        } header: {
            Text("阅读器联动与缓存")
        } footer: {
            Text("开启自动跟随后，只要在阅读器点亮「译」按钮，翻页时会自动翻译当前页并静默预翻下一页。同页再次翻回直接读取本地缓存，不重复消耗额度。")
        }
    }

    private func runConnectionTest() {
        isTestingConnection = true
        testStatusOK = nil
        testStatusMessage = nil
        Task {
            let outcome = await manager.testAIConnection()
            isTestingConnection = false
            testStatusOK = outcome.ok
            testStatusMessage = outcome.message
        }
    }
}
