import SwiftUI

/// 在线图源管理页
public struct SourceManagementView: View {
    @EnvironmentObject private var store: AppStore

    @State private var showingAddSheet = false
    @State private var showingSpecSheet = false

    public var body: some View {
        NavigationStack {
            List {
                Section("已配置的在线源") {
                    ForEach($store.sources) { $source in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(source.name)
                                    .font(.headline)
                                Text(source.kind.displayName)
                                    .font(.caption)
                                    .foregroundStyle(.tint)
                                Text(source.baseURL)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Toggle("", isOn: $source.isEnabled)
                                .labelsHidden()
                        }
                        .padding(.vertical, 2)
                    }
                    .onDelete { offsets in
                        for idx in offsets {
                            let target = store.sources[idx]
                            if target.kind != .demo {
                                store.removeSource(id: target.id)
                            }
                        }
                    }
                }

                Section {
                    Button {
                        showingSpecSheet = true
                    } label: {
                        Label("查看自定义 JSON 在线源接口规范", systemImage: "doc.text")
                    }
                } footer: {
                    Text("所有在线源均通过标准 MangaSourceProtocol 接入，后续可继续扩展 Komga、Kavita、OPDS 或任意自建接口。")
                }
            }
            .navigationTitle("在线源")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingAddSheet = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("新增在线源")
                }
            }
            .sheet(isPresented: $showingAddSheet) {
                AddSourceSheet { newSource in
                    store.addSource(newSource)
                }
            }
            .sheet(isPresented: $showingSpecSheet) {
                JSONSpecSheet()
            }
        }
    }
}

private struct AddSourceSheet: View {
    @Environment(\.dismiss) private var dismiss

    let onAdd: (MangaSourceConfig) -> Void

    @State private var name = ""
    @State private var baseURL = "https://"
    @State private var authHeader = ""
    @State private var refererHeader = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("基本信息") {
                    TextField("书源名称（如：自建漫画库）", text: $name)
                    TextField("接口 Base URL", text: $baseURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section("可选请求头") {
                    TextField("Authorization（可选）", text: $authHeader)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Referer（防盗链可选）", text: $refererHeader)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }
            .navigationTitle("新增 JSON 在线源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        var headers: [String: String] = [:]
                        if !authHeader.trimmingCharacters(in: .whitespaces).isEmpty {
                            headers["Authorization"] = authHeader.trimmingCharacters(in: .whitespaces)
                        }
                        if !refererHeader.trimmingCharacters(in: .whitespaces).isEmpty {
                            headers["Referer"] = refererHeader.trimmingCharacters(in: .whitespaces)
                        }
                        let source = MangaSourceConfig(
                            name: name.trimmingCharacters(in: .whitespaces),
                            kind: .genericJSON,
                            baseURL: baseURL.trimmingCharacters(in: .whitespaces),
                            headers: headers,
                            isEnabled: true
                        )
                        onAdd(source)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || URL(string: baseURL) == nil)
                }
            }
        }
    }
}

private struct JSONSpecSheet: View {
    @Environment(\.dismiss) private var dismiss

    private let specText = """
    自定义 JSON 在线源需提供以下 4 个 GET 接口：

    1. 热门列表
       GET {baseURL}/popular?page=1
       返回: [{ "id", "title", "author", "coverURL", "summary", "tags", "statusText" }]

    2. 关键词搜索
       GET {baseURL}/search?q=关键词&page=1
       返回同上

    3. 章节列表
       GET {baseURL}/manga/{id}/chapters
       返回: [{ "id", "title", "number", "updatedAt" }]

    4. 章节页面图片
       GET {baseURL}/chapter/{id}/pages
       返回: [{ "index", "imageURL", "headers" }]
    """

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(specText)
                    .font(.system(.footnote, design: .monospaced))
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("在线源接口规范")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}
