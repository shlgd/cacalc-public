import SwiftUI
import UIKit

/// The outer navigation transition moves complete screens, including their bars.
/// Each hosting controller retains its own SwiftUI navigation/tab container.
struct MealScreenNavigation<Root: View, Destination: View>: UIViewControllerRepresentable {
    @Binding var showing: Bool
    let saving: Bool
    let root: Root
    let destination: Destination

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIViewController(context: Context) -> UINavigationController {
        let coordinator = context.coordinator
        let navigation = UINavigationController(rootViewController: coordinator.root)
        navigation.setNavigationBarHidden(true, animated: false)
        navigation.delegate = coordinator
        navigation.interactivePopGestureRecognizer?.delegate = coordinator
        navigation.interactiveContentPopGestureRecognizer?.delegate = coordinator
        coordinator.navigation = navigation
        return navigation
    }
    func updateUIViewController(_ navigation: UINavigationController, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.root.rootView = root
        coordinator.detail?.rootView = destination
        coordinator.reconcile()
    }
    final class Coordinator: NSObject, UINavigationControllerDelegate, UIGestureRecognizerDelegate {
        var parent: MealScreenNavigation
        let root: UIHostingController<Root>
        var detail: UIHostingController<Destination>?
        weak var navigation: UINavigationController?
        private var transitioning = false

        init(_ parent: MealScreenNavigation) {
            self.parent = parent
            root = UIHostingController(rootView: parent.root)
            super.init()
        }
        func reconcile() {
            guard let navigation, navigation.viewIfLoaded?.window != nil,
                  !transitioning, navigation.transitionCoordinator == nil else { return }
            if parent.showing, detail == nil {
                let screen = UIHostingController(rootView: parent.destination)
                screen.view.backgroundColor = .systemGroupedBackground
                detail = screen
                navigation.pushViewController(screen, animated: !UIAccessibility.isReduceMotionEnabled)
            } else if !parent.showing, detail != nil, navigation.topViewController !== root {
                navigation.popToRootViewController(animated: !UIAccessibility.isReduceMotionEnabled)
            }
        }
        func navigationController(_ navigationController: UINavigationController, willShow viewController: UIViewController, animated: Bool) {
            transitioning = true
        }
        func navigationController(_ navigationController: UINavigationController, didShow viewController: UIViewController, animated: Bool) {
            transitioning = false
            if viewController === root, detail != nil {
                detail = nil
                // didShow is called for the final controller, including cancelled swipes.
                // Only a completed pop changes the session and triggers draft persistence.
                if parent.showing { parent.showing = false }
            }
            navigationController.interactivePopGestureRecognizer?.isEnabled = navigationController.viewControllers.count > 1
            navigationController.interactiveContentPopGestureRecognizer?.isEnabled = navigationController.viewControllers.count > 1
            Task { @MainActor [weak self] in
                await Task.yield()
                self?.reconcile()
            }
        }
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard !parent.saving, !transitioning, let detail,
                  navigation?.topViewController === detail,
                  detail.presentedViewController == nil else { return false }
            if let pan = gestureRecognizer as? UIPanGestureRecognizer {
                let velocity = pan.velocity(in: pan.view)
                let direction: CGFloat = pan.view?.effectiveUserInterfaceLayoutDirection == .rightToLeft ? -1 : 1
                guard velocity.x * direction > abs(velocity.y) else { return false }
            }
            // Let the inner stack own gestures while a product editor is open.
            return !hasPushedChild(detail)
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            guard let detail, !hasPushedChild(detail),
                  let scroll = other.view as? UIScrollView,
                  other === scroll.panGestureRecognizer,
                  scroll.isDescendant(of: detail.view) else { return false }
            // Vertical pans proceed as soon as the horizontal pop rejects them.
            // A fresh back swipe also takes priority while the list is decelerating.
            return true
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRequireFailureOf other: UIGestureRecognizer) -> Bool {
            gestureRecognizer === navigation?.interactiveContentPopGestureRecognizer
                && other === navigation?.interactivePopGestureRecognizer
        }
        private func hasPushedChild(_ controller: UIViewController) -> Bool {
            if let navigation = controller as? UINavigationController, navigation.viewControllers.count > 1 { return true }
            return controller.children.contains { hasPushedChild($0) }
        }
    }
}
