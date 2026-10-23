import SwiftUI
import UIKit

/// Keep UIKit search from collapsing the navigation bar while SwiftUI fades its controls.
struct MealSearchNavigationPolicy: UIViewControllerRepresentable {
    @Binding var navigationBarHeight: CGFloat
    let toolbarFade: MealToolbarFade
    func makeUIViewController(context: Context) -> Controller {
        let controller = Controller()
        controller.reportHeight = { navigationBarHeight = $0 }
        controller.toolbarFade = toolbarFade
        return controller
    }
    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.reportHeight = { navigationBarHeight = $0 }
        controller.toolbarFade = toolbarFade
        controller.configureSearch()
        // SwiftUI may attach its search controller after this representable's update.
        DispatchQueue.main.async { [weak controller] in controller?.configureSearch() }
    }
    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) {
        controller.restore()
    }

    final class Controller: UIViewController {
        var reportHeight: ((CGFloat) -> Void)?
        weak var toolbarFade: MealToolbarFade?
        private var reportedHeight: CGFloat?
        private weak var configuredSearch: UISearchController?
        private var originalHiding: Bool?
        private var detached = false

        override func loadView() {
            view = UIView()
            view.isUserInteractionEnabled = false
        }
        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            if parent != nil { configureSearch() }
        }
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            configureSearch()
            toolbarFade?.setScreenVisible(true)
            DispatchQueue.main.async { [weak self] in self?.toolbarFade?.captureIdleControls() }
        }
        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            toolbarFade?.setScreenVisible(false)
        }
        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            configureSearch()
        }
        func configureSearch() {
            guard !detached else { return }
            if let window = viewIfLoaded?.window { toolbarFade?.window = window }
            var ancestor = parent
            while let owner = ancestor {
                let search = owner.navigationItem.searchController
                    ?? (owner as? UINavigationController)?.topViewController?.navigationItem.searchController
                if let search {
                    if let navigation = (owner as? UINavigationController) ?? owner.navigationController {
                        toolbarFade?.toolbar = navigation.toolbar
                        let height = navigation.navigationBar.bounds.height
                        if height > 0, reportedHeight != height {
                            reportedHeight = height
                            DispatchQueue.main.async { [weak self] in
                                guard let self, !self.detached else { return }
                                self.reportHeight?(height)
                            }
                        }
                    }
                    if configuredSearch !== search {
                        restoreValue()
                        configuredSearch = search
                        originalHiding = search.hidesNavigationBarDuringPresentation
                    }
                    if search.hidesNavigationBarDuringPresentation {
                        search.hidesNavigationBarDuringPresentation = false
                    }
                    return
                }
                ancestor = owner.parent
            }
        }
        func restore() {
            detached = true
            toolbarFade?.setScreenVisible(false)
            restoreValue()
        }
        private func restoreValue() {
            if let search = configuredSearch, let originalHiding,
               !search.hidesNavigationBarDuringPresentation {
                search.hidesNavigationBarDuringPresentation = originalHiding
            }
            configuredSearch = nil
            originalHiding = nil
        }
    }
}
