import SwiftUI
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit

/// 基于原生 UIDocumentPickerViewController(asCopy: true) 的本地漫画文档选择器
/// 相比 SwiftUI .fileImporter：
/// 1. 系统自动将 iCloud Drive / 第三方云盘 / 文件 App 中的文档安全拷贝进临时沙盒，避免安全作用域权限失效；
/// 2. 独立以 .sheet 弹出，彻底避免与同级 .sheet / Menu 发生 SwiftUI 回调丢失；
/// 3. 默认显示文件扩展名，支持 CBZ / ZIP / PDF / EPUB 多选导入。
public struct LocalMangaDocumentPicker: UIViewControllerRepresentable {
    public let contentTypes: [UTType]
    public let allowsMultipleSelection: Bool
    public let onPick: ([URL]) -> Void
    public let onCancel: () -> Void

    public init(
        contentTypes: [UTType] = LocalMangaLibraryManager.supportedImportContentTypes,
        allowsMultipleSelection: Bool = true,
        onPick: @escaping ([URL]) -> Void,
        onCancel: @escaping () -> Void = {}
    ) {
        self.contentTypes = contentTypes
        self.allowsMultipleSelection = allowsMultipleSelection
        self.onPick = onPick
        self.onCancel = onCancel
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick, onCancel: onCancel)
    }

    public func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let types = contentTypes.isEmpty ? [.data, .archive, .pdf] : contentTypes
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        picker.allowsMultipleSelection = allowsMultipleSelection
        picker.shouldShowFileExtensions = true
        picker.delegate = context.coordinator
        return picker
    }

    public func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {
        context.coordinator.onPick = onPick
        context.coordinator.onCancel = onCancel
    }

    public final class Coordinator: NSObject, UIDocumentPickerDelegate {
        var onPick: ([URL]) -> Void
        var onCancel: () -> Void

        init(onPick: @escaping ([URL]) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick
            self.onCancel = onCancel
        }

        public func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            DispatchQueue.main.async {
                self.onPick(urls)
            }
        }

        public func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            DispatchQueue.main.async {
                self.onCancel()
            }
        }
    }
}
#endif
