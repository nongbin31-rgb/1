import SwiftUI
import UIKit

/// 封装单页漫画视图的 UIHostingController
public final class ComicPageHostingController: UIHostingController<ComicPageCellView> {
    public let pageIndex: Int

    public init(
        pageIndex: Int,
        page: MangaPage,
        config: ImageUpscalerConfig,
        isCompareMode: Bool,
        showSpineShadow: Bool,
        isRightToLeft: Bool,
        onSingleTap: @escaping () -> Void,
        onStatusUpdate: @escaping (String) -> Void,
        onZoomChanged: ((CGFloat) -> Void)? = nil
    ) {
        self.pageIndex = pageIndex
        let rootView = ComicPageCellView(
            page: page,
            config: config,
            isCompareMode: isCompareMode,
            showSpineShadow: showSpineShadow,
            isRightToLeft: isRightToLeft,
            onSingleTap: onSingleTap,
            onStatusUpdate: onStatusUpdate,
            onZoomChanged: onZoomChanged
        )
        super.init(rootView: rootView)
    }

    @MainActor required dynamic init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
    }
}
