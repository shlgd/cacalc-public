import UIKit
import SwiftUI

/// Keeps the native side visuals for both directions of the dictation transition.
/// No toolbar ownership, search delegates or hit targets are replaced.
@MainActor final class MealToolbarFade {
    weak var toolbar: UIToolbar?
    weak var window: UIWindow?
    var scannerFrame: CGRect = .zero
    var microphoneFrame: CGRect = .zero
    weak var visualHost: UIView?
    private var snapshots: [UIView] = []
    private var returnAnimator: UIViewPropertyAnimator?
    private var handoffTask: Task<Void, Never>?
    private struct IdleControl {
        let view: UIView
        let frame: CGRect
    }
    private var idleControls: [IdleControl] = []
    private var screenVisible = false
    private var controlsIdle = true

    func setScreenVisible(_ visible: Bool) {
        screenVisible = visible
        if !visible { idleControls = [] }
    }

    func captureIdleControls() {
        guard screenVisible, controlsIdle, snapshots.isEmpty, !scannerFrame.isEmpty, !microphoneFrame.isEmpty,
              let window = toolbar?.window ?? window,
              let visualHost, visualHost.window === window else { return }
        let y = scannerFrame.midY
        let landmarks = [scannerFrame.midX, microphoneFrame.midX,
                         2 * microphoneFrame.midX - scannerFrame.midX]
        var candidates: [CGRect] = []
        func collect(_ view: UIView) {
            guard !view.isHidden, view.alpha > 0.01 else { return }
            let frame = view.convert(view.bounds, to: window)
            guard frame.maxY >= y - 30 else { return }
            // Use public view geometry, without relying on private UIKit class names.
            if abs(frame.midY - y) < 4, frame.height >= 44, frame.height <= 56 {
                candidates.append(frame)
            }
            for child in view.subviews { collect(child) }
        }
        // Search only this toolbar's hosting branch, not another screen's bar.
        var barHost: UIView = visualHost
        while let parent = barHost.superview, parent !== window {
            barHost = parent
            if barHost.bounds.width >= window.bounds.width - 1,
               barHost.bounds.height >= window.bounds.height - 1 { break }
        }
        collect(barHost)
        var captured: [IdleControl] = []
        for (index, x) in landmarks.enumerated() {
            let maximumWidth = index == 1 ? microphoneFrame.width + 16 : 72
            guard let region = candidates.filter({
                abs($0.midX - x) < 12 && $0.width >= 44 && $0.width <= maximumWidth
            }).max(by: { $0.width * $0.height < $1.width * $1.height }),
                  let image = barHost.resizableSnapshotView(from: barHost.convert(region, from: window),
                    afterScreenUpdates: false, withCapInsets: .zero) else { continue }
            // Save coordinates before the press deforms the host as well as its glass.
            captured.append(IdleControl(view: image, frame: visualHost.convert(region, from: window)))
        }
        if captured.count == 3 { idleControls = captured }
    }

    func fadeSides(duration: TimeInterval, collapse: Bool) {
        cancel()
        controlsIdle = false
        guard let window = toolbar?.window ?? window,
              let visualHost, visualHost.window === window else { return }
        guard idleControls.count == 3 else { return }
        let controls = idleControls
        idleControls = []
        let target = CGPoint(x: controls[1].frame.midX, y: controls[1].frame.midY)
        for control in controls {
            let region = control.frame
            let snapshot = UIView(frame: region)
            let image = control.view
            image.frame = snapshot.bounds
            image.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            image.layer.cornerRadius = min(region.width, region.height) / 2
            image.layer.cornerCurve = .continuous
            image.clipsToBounds = true
            snapshot.addSubview(image)
            snapshot.isUserInteractionEnabled = false
            snapshot.accessibilityElementsHidden = true
            visualHost.addSubview(snapshot)
            snapshots.append(snapshot)
            UIView.animate(withDuration: duration, delay: 0,
                options: [.beginFromCurrentState, .curveEaseInOut, .allowUserInteraction]) {
                if collapse {
                    snapshot.transform = CGAffineTransform(
                        translationX: target.x - snapshot.center.x,
                        y: target.y - snapshot.center.y
                    ).scaledBy(x: 0.05, y: 0.05)
                }
                snapshot.alpha = 0
            }

        }
    }

    func restoreSides(duration: TimeInterval, fade: Bool, completion: @escaping () -> Void) {
        let returning = snapshots
        guard !returning.isEmpty else { controlsIdle = true; completion(); return }
        if !fade {
            // Reveal by geometry under the opaque recorder, not by fading glass in.
            UIView.performWithoutAnimation {
                for snapshot in returning { snapshot.alpha = 1 }
            }
        }
        let animator: UIViewPropertyAnimator
        if fade {
            animator = UIViewPropertyAnimator(duration: duration, curve: .easeOut)
        } else {
            // UIKit calculates the overshoot and settling; there are no staged target shapes.
            animator = UIViewPropertyAnimator(duration: 0.32, dampingRatio: 0.70)
        }
        returnAnimator = animator
        animator.addAnimations {
            for snapshot in returning {
                snapshot.transform = .identity
                snapshot.alpha = 1
            }
        }
        animator.addCompletion { [weak self] position in
            guard position == .end, let self,
                  returning.allSatisfy({ view in self.snapshots.contains { $0 === view } }) else { return }
            self.returnAnimator = nil
            self.controlsIdle = true
            UIView.performWithoutAnimation {
                completion()
                self.toolbar?.superview?.layoutIfNeeded()
            }
            // A main-queue turn is not a rendered SwiftUI/UIKit glass frame.
            // Keep settled visuals until native material is restored. Do not add
            // a second fade or a synthetic shadow after the spring has finished.
            self.handoffTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .milliseconds(80)) }
                catch { return }
                guard let self, self.screenVisible,
                      returning.allSatisfy({ view in self.snapshots.contains { $0 === view } }) else { return }
                UIView.performWithoutAnimation {
                    for snapshot in returning { snapshot.removeFromSuperview() }
                }
                self.snapshots.removeAll { view in returning.contains { $0 === view } }
                self.captureIdleControls()
            }
        }
        animator.startAnimation()
    }

    func cancel() {
        handoffTask?.cancel()
        handoffTask = nil
        let previous = snapshots
        snapshots.removeAll()
        returnAnimator?.stopAnimation(true)
        returnAnimator = nil
        for snapshot in previous {
            snapshot.layer.removeAllAnimations()
            snapshot.removeFromSuperview()
        }
    }
}

/// A persistent background of the central control: snapshots are behind the
/// real opaque recorder, not above the entire window. It owns no touch targets.
struct MealToolbarVisualHost: UIViewRepresentable {
    let transition: MealToolbarFade

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
        view.clipsToBounds = false
        transition.visualHost = view
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        transition.visualHost = uiView
    }
}
