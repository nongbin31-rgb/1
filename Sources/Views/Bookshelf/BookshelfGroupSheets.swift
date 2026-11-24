import SwiftUI

/// 分组选择弹窗上下文（单本精准设置 或 批量移入分组）
enum BookshelfGroupPickerContext: Identifiable {
    case single(Manga)
    case batch([Manga])

    var id: String {
        switch self {
        case .single(let manga):
            return "single::\(manga.compositeKey)"
        case .batch(let list):
            return "batch::\(list.count)::\(list.first?.compositeKey ?? "")"
        }
    }

    var navigationTitle: String {
        switch self {
        case .single:
            return "设置所属分组"
        case .batch(let list):
            return "将 \(list.count) 本移入分组"
        }
    }

    var confirmButtonTitle: String {
        switch self {
        case .single:
            return "保存"
        case .batch:
            return "移入"
        }
    }
}

/// 分组多选弹窗（支持一本漫画多分组 + 弹窗内直接新建分组）
struct BookshelfGroupPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: AppStore

    let context: BookshelfGroupPickerContext
    let onCompleted: (String) -> Void

    @State private var selectedGroupIDs: Set<String> = []
    @State private var newGroupName = ""
    @State private var newGroupIcon = BookshelfGroup.presetIcons.first ?? "folder.fill"

    private var isBatchMode: Bool {
        if case .batch = context { return true }
        return false
    }

    private func mangaCount(in groupID: String) -> Int {
        store.bookshelf.reduce(into: 0) { count, manga in
            if store.groupIDs(for: manga).contains(groupID) {
                count += 1
            }
        }
    }

    var body: some View {
        CompatNavigationContainer {
            Form {
                if case .single(let manga) = context {
                    Section {
                        HStack(spacing: 10) {
                            AsyncMangaCoverView(
                                urlString: manga.coverURL,
                                headers: manga.coverHeaders,
                                cornerRadius: 6
                            )
                            .frame(width: 36, height: 50)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                            VStack(alignment: .leading, spacing: 2) {
                                Text(MangaTitleMetadataParser.parse(title: manga.title, author: manga.displayAuthor).cleanTitle)
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(2)
                                Text("可同时勾选多个分组")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }

                Section {
                    if store.bookshelfGroups.isEmpty {
                        HStack(spacing: 10) {
                            Image(systemName: "folder.badge.plus")
                                .foregroundStyle(.secondary)
                            Text("还没有自定义分组，可在下方快速新建。")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    } else {
                        ForEach(store.bookshelfGroups) { group in
                            let isChecked = selectedGroupIDs.contains(group.id)
                            let count = mangaCount(in: group.id)

                            Button {
                                if isChecked {
                                    selectedGroupIDs.remove(group.id)
                                } else {
                                    selectedGroupIDs.insert(group.id)
                                }
                                BookshelfHaptics.light()
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: group.iconName)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundColor(isChecked ? .accentColor : .secondary)
                                        .frame(width: 24)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(group.name)
                                            .font(.body)
                                            .foregroundStyle(.primary)
                                        Text("\(count) 本漫画")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }

                                    Spacer()

                                    Image(systemName: isChecked ? "checkmark.circle.fill" : "circle")
                                        .font(.title3)
                                        .foregroundColor(isChecked ? .accentColor : .secondary.opacity(0.45))
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } header: {
                    Text(isBatchMode ? "选择要移入的目标分组（可多选）" : "选择所属分组（可多选）")
                }

                Section {
                    HStack(spacing: 10) {
                        TextField("输入新分组名称（如：追更韩漫）", text: $newGroupName)
                            .submitLabel(.done)
                            .onSubmit {
                                createAndSelectGroup()
                            }

                        Button("新建") {
                            createAndSelectGroup()
                        }
                        .font(.subheadline.weight(.semibold))
                        .disabled(newGroupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }

                    BookshelfGroupIconPickerRow(selectedIcon: $newGroupIcon)
                } header: {
                    Text("快捷新建分组")
                }
            }
            .navigationTitle(context.navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(context.confirmButtonTitle) {
                        applySelection()
                    }
                    .disabled(isBatchMode && selectedGroupIDs.isEmpty)
                }
            }
            .onAppear {
                if case .single(let manga) = context {
                    selectedGroupIDs = store.groupIDs(for: manga)
                }
            }
        }
    }

    private func createAndSelectGroup() {
        guard let created = store.createBookshelfGroup(name: newGroupName, iconName: newGroupIcon) else {
            return
        }
        selectedGroupIDs.insert(created.id)
        newGroupName = ""
        BookshelfHaptics.light()
    }

    private func applySelection() {
        switch context {
        case .single(let manga):
            store.setGroups(selectedGroupIDs, for: manga)
            BookshelfHaptics.medium()
            let msg = selectedGroupIDs.isEmpty
                ? "已清除该漫画的分组"
                : "已更新分组（\(selectedGroupIDs.count) 个）"
            dismiss()
            onCompleted(msg)

        case .batch(let mangas):
            store.addMangas(mangas, toGroups: selectedGroupIDs)
            BookshelfHaptics.medium()
            let msg = "已将 \(mangas.count) 本漫画加入 \(selectedGroupIDs.count) 个分组"
            dismiss()
            onCompleted(msg)
        }
    }
}

/// 分组管理弹窗（新建、重命名、换图标、拖拽排序、左滑删除）
struct BookshelfGroupManagerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: AppStore

    @State private var newGroupName = ""
    @State private var newGroupIcon = BookshelfGroup.presetIcons.first ?? "folder.fill"
    @State private var editingGroup: BookshelfGroup?
    @State private var editNameInput = ""
    @State private var editIconInput = "folder.fill"
    @State private var pendingDeleteGroup: BookshelfGroup?

    private func mangaCount(in groupID: String) -> Int {
        store.bookshelf.reduce(into: 0) { count, manga in
            if store.groupIDs(for: manga).contains(groupID) {
                count += 1
            }
        }
    }

    var body: some View {
        CompatNavigationContainer {
            List {
                Section {
                    HStack(spacing: 10) {
                        TextField("新分组名称（如：精选单本、同人收藏）", text: $newGroupName)
                            .submitLabel(.done)
                            .onSubmit {
                                createGroup()
                            }

                        Button("添加") {
                            createGroup()
                        }
                        .font(.subheadline.weight(.semibold))
                        .disabled(newGroupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }

                    BookshelfGroupIconPickerRow(selectedIcon: $newGroupIcon)
                } header: {
                    Text("新建书架分组")
                }

                Section {
                    if store.bookshelfGroups.isEmpty {
                        Text("暂无自定义分组，创建首个分组后书架顶部将自动显示分组切换栏。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 6)
                    } else {
                        ForEach(store.bookshelfGroups) { group in
                            let count = mangaCount(in: group.id)
                            HStack(spacing: 12) {
                                Image(systemName: group.iconName)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundColor(.accentColor)
                                    .frame(width: 24)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(group.name)
                                        .font(.body.weight(.medium))
                                    Text("\(count) 本漫画")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                Button {
                                    editNameInput = group.name
                                    editIconInput = group.iconName
                                    editingGroup = group
                                } label: {
                                    Text("编辑")
                                        .font(.caption.weight(.semibold))
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .background(Color(uiColor: .secondarySystemFill), in: Capsule())
                                        .foregroundStyle(.primary)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.vertical, 2)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    pendingDeleteGroup = group
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                        }
                        .onMove { source, destination in
                            store.moveBookshelfGroups(fromOffsets: source, toOffset: destination)
                        }
                    }
                } header: {
                    Text("已建分组（可拖动调整顺序）")
                } footer: {
                    Text("删除分组仅解除分类归属，不会删除书架中的漫画本身；一本漫画可同时属于多个分组。")
                }
            }
            .navigationTitle("管理书架分组")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !store.bookshelfGroups.isEmpty {
                        EditButton()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .sheet(item: $editingGroup) { target in
                CompatNavigationContainer {
                    Form {
                        Section("分组名称") {
                            TextField("输入分组名称", text: $editNameInput)
                        }
                        Section("分组图标") {
                            BookshelfGroupIconPickerRow(selectedIcon: $editIconInput)
                        }
                    }
                    .navigationTitle("编辑分组")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("取消") { editingGroup = nil }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("保存") {
                                store.renameBookshelfGroup(
                                    id: target.id,
                                    name: editNameInput,
                                    iconName: editIconInput
                                )
                                editingGroup = nil
                                BookshelfHaptics.light()
                            }
                            .disabled(editNameInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                }
                .compatPresentationDetentsHeight(320)
                .compatPresentationDragIndicatorVisible()
            }
            .alert(
                "删除分组「\(pendingDeleteGroup?.name ?? "")」？",
                isPresented: Binding(
                    get: { pendingDeleteGroup != nil },
                    set: { if !$0 { pendingDeleteGroup = nil } }
                )
            ) {
                Button("取消", role: .cancel) { pendingDeleteGroup = nil }
                Button("删除", role: .destructive) {
                    if let target = pendingDeleteGroup {
                        store.deleteBookshelfGroup(id: target.id)
                        BookshelfHaptics.medium()
                    }
                    pendingDeleteGroup = nil
                }
            } message: {
                Text("仅删除该分组，书架中的漫画和阅读进度都会保留。")
            }
        }
    }

    private func createGroup() {
        guard store.createBookshelfGroup(name: newGroupName, iconName: newGroupIcon) != nil else {
            return
        }
        newGroupName = ""
        BookshelfHaptics.light()
    }
}

/// 预设分组图标横向选择器
private struct BookshelfGroupIconPickerRow: View {
    @Binding var selectedIcon: String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(BookshelfGroup.presetIcons, id: \.self) { icon in
                    let isSelected = (selectedIcon == icon)
                    Button {
                        selectedIcon = icon
                        BookshelfHaptics.light()
                    } label: {
                        Image(systemName: icon)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(isSelected ? .white : .secondary)
                            .frame(width: 34, height: 34)
                            .background(
                                Circle().fill(isSelected ? Color.accentColor : Color(uiColor: .secondarySystemFill))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 4)
        }
    }
}
