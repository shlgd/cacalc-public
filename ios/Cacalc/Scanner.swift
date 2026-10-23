import SwiftUI
import VisionKit
import AVFoundation

struct ScannerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var permitted = false
    @State private var checked = false
    @State private var issue: String?
    let receive: (String) -> Void
    var unavailableMessage = "Вернитесь к поиску и введите название или штрихкод. Доступ к камере можно разрешить в настройках iPhone."
    var returnTitle = "Вернуться к поиску"
    var body: some View {
        UsageScreen("ScannerSheet") {
        NavigationStack {
            Group {
                if checked && permitted && DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                    NativeScanner(receive: receive, failure: { issue = $0 })
                        .overlay(alignment: .bottom) {
                            Text("Наведите камеру на обычный штрихкод упаковки")
                                .font(.subheadline).padding().background(.regularMaterial, in: Capsule()).padding()
                        }
                } else if checked {
                    ContentUnavailableView("Камера недоступна", systemImage: "barcode.viewfinder",
                        description: Text(unavailableMessage))
                        .accessibilityIdentifier("scannerUnavailable")
                } else { ProgressView() }
            }
            .navigationTitle("Штрихкод").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) {
                Button("Закрыть") { UsageTelemetry.shared.action("Scanner.button.30"); dismiss() }.accessibilityIdentifier("closeScanner")
            } }
            .task {
                guard DataScannerViewController.isSupported else { checked = true; return }
                let status = AVCaptureDevice.authorizationStatus(for: .video)
                if status == .notDetermined { permitted = await AVCaptureDevice.requestAccess(for: .video) }
                else { permitted = status == .authorized }
                checked = true
            }
            .alert("Не удалось запустить камеру", isPresented: Binding(get: { issue != nil }, set: { if !$0 { issue = nil } })) {
                Button(returnTitle) { UsageTelemetry.shared.action("Scanner.button.40"); dismiss() }
            } message: { Text(issue ?? "") }
        }
            }
}
}

@MainActor final class ScanGate {
    private(set) var accepted = false
    func accept(_ code: String) -> Bool {
        guard !accepted, Barcode.valid(code) else { return false }
        accepted = true; return true
    }
}

struct NativeScanner: UIViewControllerRepresentable {
    let receive: (String) -> Void
    let failure: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(receive: receive, failure: failure) }
    func makeUIViewController(context: Context) -> DataScannerViewController {
        let controller = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.ean13, .ean8, .itf14])],
            qualityLevel: .balanced, recognizesMultipleItems: false, isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: true, isGuidanceEnabled: true, isHighlightingEnabled: true)
        controller.delegate = context.coordinator
        do { try controller.startScanning() } catch { context.coordinator.failure(error.localizedDescription) }
        return controller
    }
    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}
    static func dismantleUIViewController(_ controller: DataScannerViewController, coordinator: Coordinator) { controller.stopScanning() }
    @MainActor final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let receive: (String) -> Void
        let failure: (String) -> Void
        let gate = ScanGate()
        init(receive: @escaping (String) -> Void, failure: @escaping (String) -> Void) { self.receive = receive; self.failure = failure }
        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            for item in addedItems {
                if case .barcode(let barcode) = item, let code = barcode.payloadStringValue, gate.accept(code) {
                    dataScanner.stopScanning(); receive(code); return
                }
            }
        }
        func dataScanner(_ dataScanner: DataScannerViewController, becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable) {
            failure(error.localizedDescription)
        }
    }
}
