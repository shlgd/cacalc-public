import SwiftUI
import UIKit

/// Simple variant: keep the toolbar's native glass and change only its contents.
struct MealInlineDictationControl: View {
    let voice: VoiceSession
    let active: Bool
    let reduceMotion: Bool
    let blocked: Bool
    let start: () -> Void
    let finish: () -> Void
    @Binding var recorderFrame: CGRect
    @State private var suppressTapUntil = Date.distantPast
    @State private var closingWave = false

    var body: some View {
        Button { UsageTelemetry.shared.action("MealDictationControl.button.17");
            guard Date() >= suppressTapUntil, !blocked else { return }
            suppressTapUntil = Date().addingTimeInterval(0.25)
            if active {
                guard voice.capturing else { return }
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                closingWave = true
                finish()
            } else {
                closingWave = false
                start()
            }
        } label: {
            ZStack {
                Image(systemName: "mic.fill")
                    .font(.title3)
                    .scaleEffect(x: 1, y: active ? 0 : 1)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.14)
                        .delay(active ? 0 : 0.10), value: active)
                MealDictationWave(voice: voice, reduceMotion: reduceMotion,
                                 preparing: active && !voice.capturing && !voice.processing, reveal: active ? 1 : 0, closing: closingWave)
                    .frame(width: 128, height: 28)
                    .animation(reduceMotion ? nil : .linear(duration: active ? 0.16 : 0.17)
                        .delay(active ? 0.06 : 0), value: active)
            }
            .frame(width: 184, height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(MealRecorderContentStyle())
        .buttonBorderShape(.capsule)
        .disabled(blocked)
        .accessibilityLabel(active ? "Завершить запись" : "Продиктовать еду")
        .accessibilityIdentifier("dictateMeal")
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
            recorderFrame = $0
        }
    }
}

/// Keep label colors unchanged when pressed. The toolbar still owns its glass background.
private struct MealRecorderContentStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

/// SuperDictate-style dot growth, with independent horizontal and vertical settling.
struct MealDictationControl: View {
    let voice: VoiceSession
    let toolbarFade: MealToolbarFade
    let presented: Bool
    let restoring: Bool
    let reduceMotion: Bool
    let blocked: Bool
    let start: () -> Void
    @Binding var recorderFrame: CGRect
    private var active: Bool { presented }
    private var mergeAnimation: Animation { reduceMotion ? .easeOut(duration: 0.12) : .easeInOut(duration: active ? 0.28 : 0.18) }

    var body: some View {
        ZStack {
            Button(action: usageAction("MealDictationControl.button.78", start)) {
                Image(systemName: "mic.fill").font(.title3)
                    .frame(width: 152, height: 28)
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                if !active && !restoring { toolbarFade.microphoneFrame = $0 }
            }
            .opacity(active || restoring ? 0 : 1)
            .allowsHitTesting(!active && !restoring && !blocked)
            .accessibilityHidden(active)
            .accessibilityLabel("Продиктовать еду")
            .accessibilityIdentifier("dictateMeal")


        }
        .background(MealToolbarVisualHost(transition: toolbarFade))
        .task(id: active || restoring) {
            guard !active && !restoring else { return }
            do {
                // Wait for the native glass to settle after insertion, never at tap time.
                try await Task.sleep(for: .milliseconds(100))
                try Task.checkCancellation()
                toolbarFade.captureIdleControls()
            } catch { }
        }
        .onChange(of: presented) { _, _ in MealAnimationProbe.shared.mark("view presented changed") }
        .frame(width: 152, height: active ? 68 : 28)
        .animation(mergeAnimation, value: active)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
            recorderFrame = $0
        }
    }
}

/// Rendered by the screen overlay, outside the bottom toolbar's glass environment.
/// Remains mounted while idle so both directions share one animation state.
struct MealRecordingCapsule: View {
    let voice: VoiceSession
    let active: Bool
    let reduceMotion: Bool
    let blocked: Bool
    let status: String
    let finish: () -> Void
    @State private var speechLevel = 0.0
    @State private var suppressTapUntil = Date.distantPast
    @GestureState private var drag: CGSize = .zero

    private func finishRecording() {
        guard Date() >= suppressTapUntil, !blocked, voice.capturing else { return }
        suppressTapUntil = Date().addingTimeInterval(0.25)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        finish()
    }

    var body: some View {
            Button(action: usageAction("MealDictationControl.button.133", finishRecording)) {
                HStack(spacing: 14) {
                    MealDictationWave(voice: voice, reduceMotion: reduceMotion, preparing: active && !voice.locked, onLevel: { speechLevel = $0 })
                        .frame(width: 44, height: 36)
                    Text(status)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentTransition(.opacity)
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: status)
                }
                    .padding(.horizontal, 24)
                    .frame(width: 304, height: 68)
                    .contentShape(Capsule())
                    .background(MealRecorderTapArea(enabled: active && !blocked && voice.capturing,
                                                    action: usageAction("MealDictationControl.recorderTap", finishRecording)))
            }
            .buttonStyle(MealRecorderPressStyle(reduceMotion: reduceMotion))
            .modifier(MealRecorderReveal(progress: active ? 1 : 0, closing: !active, reduceMotion: reduceMotion))
            .scaleEffect(x: reduceMotion ? 1 : 1 + speechLevel * 0.04 + abs(drag.width) / 600,
                         y: reduceMotion ? 1 : 1 + speechLevel * 0.02 - abs(drag.width) / 1200)
            .offset(x: reduceMotion ? 0 : drag.width * 0.25, y: reduceMotion ? 0 : drag.height * 0.18)
            .animation(reduceMotion ? nil : .linear(duration: active ? 0.28 : 0.18), value: active)
            .animation(reduceMotion ? nil : .spring(duration: 0.25, bounce: 0.15), value: drag)
            .simultaneousGesture(
                DragGesture(minimumDistance: 6)
                    .onChanged { _ in if active { suppressTapUntil = .distantFuture } }
                    .onEnded { _ in suppressTapUntil = Date().addingTimeInterval(0.2) }
                    .updating($drag) { value, state, _ in
                        guard active else { return }
                        state = CGSize(width: max(-24, min(24, value.translation.width)),
                                       height: max(-16, min(16, value.translation.height)))
                    }
            )
            .allowsHitTesting(active && !blocked)
            .accessibilityHidden(!active)
            .accessibilityLabel(voice.processing ? "Распознаю на iPhone" : "Завершить запись")
            .accessibilityValue(status)
    }
}

/// Keep the existing press geometry; the system glass supplies its own material.
private struct MealRecorderPressStyle: ButtonStyle {
    let reduceMotion: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 1.06 : 1))
            .animation(reduceMotion ? nil : .spring(duration: 0.18, bounce: 0.16), value: configuration.isPressed)
    }
}


/// One timeline draws a genuinely rounded contour and independently fades the
/// full-size bars. No second reveal modifier or scaled capsule image is involved.
nonisolated private struct MealRecorderReveal: AnimatableModifier {
    var progress: Double
    var closing: Bool
    var reduceMotion: Bool
    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let t = min(1, max(0, progress))
        // Move through the micro-point immediately, then ease into the same peak.
        // Cubic ease-out avoids the long near-zero tail of quintic ease-in/out.
        let openingTime = min(1, t / 0.68)
        let opening = 1 - pow(1 - openingTime, 3)
        let settle = 1 + 0.08 * (t <= 0.68 ? opening : 1 - smootherstep((t - 0.68) / 0.32))
        let openingWidth = (1 + 303 * opening * opening * opening) * settle
        let openingHeight = min(openingWidth, (1 + 67 * opening * opening) * settle)
        let width = reduceMotion ? 304 : (closing ? 1 + 303 * t * t * t : openingWidth)
        // Closing is unchanged: width catches up with height, then a point.
        let height = reduceMotion ? 68 : (closing ? min(width, 1 + 67 * t * t) : openingHeight)
        let barsAlpha = reduceMotion ? 1 : (closing
            ? smootherstep((t - 0.65) / 0.35)
            : smootherstep((t - 0.35) / 0.65))
        let shape = Capsule().frame(width: width, height: height)
        content
            .opacity(barsAlpha)
            .mask(shape)
            .background {
                // Give the glass the animated contour's bounds, not the fixed
                // toolbar host. Keep one material throughout the transition.
                Color.clear
                    .frame(width: width, height: height)
                    .glassEffect(.regular, in: .capsule)
                    .allowsHitTesting(false)
            }
            .offset(y: -16)
            .opacity(reduceMotion ? t : (t > 0.001 ? 1 : 0))
    }

    private func smootherstep(_ value: Double) -> Double {
        let t = min(1, max(0, value))
        return t * t * t * (t * (t * 6 - 15) + 10)
    }
}


/// The recorder draws beyond the native toolbar item's bounds. Observe taps at
/// the window, but accept only this visible capsule; never resize the toolbar.
private struct MealRecorderTapArea: UIViewRepresentable {
    let enabled: Bool
    let action: () -> Void

    func makeUIView(context: Context) -> TapAreaView { TapAreaView() }
    func updateUIView(_ view: TapAreaView, context: Context) {
        view.action = action
        view.tap.isEnabled = enabled
    }
    static func dismantleUIView(_ view: TapAreaView, coordinator: ()) {
        view.tap.view?.removeGestureRecognizer(view.tap)
        view.action = nil
    }

    final class TapAreaView: UIView, UIGestureRecognizerDelegate {
        var action: (() -> Void)?
        lazy var tap: UITapGestureRecognizer = {
            let recognizer = UITapGestureRecognizer(target: self, action: #selector(tapped))
            recognizer.delegate = self
            recognizer.cancelsTouchesInView = false
            recognizer.delaysTouchesBegan = false
            recognizer.delaysTouchesEnded = false
            return recognizer
        }()

        init() {
            super.init(frame: .zero)
            backgroundColor = .clear
            isUserInteractionEnabled = false
            accessibilityElementsHidden = true
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            tap.view?.removeGestureRecognizer(tap)
            window?.addGestureRecognizer(tap)
        }

        private func containsTap(_ point: CGPoint) -> Bool {
            UIBezierPath(roundedRect: bounds, cornerRadius: bounds.height / 2).contains(point)
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard window != nil, !bounds.isEmpty else { return false }
            return containsTap(touch.location(in: self))
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }
        @objc private func tapped() {
            guard tap.state == .ended, containsTap(tap.location(in: self)) else { return }
            action?()
        }
    }
}
