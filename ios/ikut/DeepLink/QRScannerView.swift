import SwiftUI
import VisionKit

/// Full-screen QR scanner sheet. Calls `onCode` with a trip code once a joinable QR is seen, then dismisses.
struct QRScannerView: View {
    @Environment(\.dismiss) private var dismiss
    var onCode: (String) -> Void

    /// False on devices without a usable camera scanner (or when camera access is denied).
    @MainActor static var isAvailable: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }

    var body: some View {
        NavigationStack {
            ScannerRepresentable { text in
                guard let code = DeepLink.joinCode(fromScanned: text) else { return false }
                onCode(code)
                dismiss()
                return true
            }
            .ignoresSafeArea()
            .navigationTitle("Scan QR code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

private struct ScannerRepresentable: UIViewControllerRepresentable {
    /// Returns true when the text was accepted, which stops further scanning.
    var onText: (String) -> Bool

    func makeCoordinator() -> Coordinator { Coordinator(onText: onText) }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        context.coordinator.onText = onText
        if !context.coordinator.started {
            context.coordinator.started = true
            try? scanner.startScanning()
        }
    }

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        scanner.stopScanning()
    }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var onText: (String) -> Bool
        var started = false
        private var done = false

        init(onText: @escaping (String) -> Bool) { self.onText = onText }

        func dataScanner(_ scanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !done else { return }
            for case .barcode(let barcode) in addedItems {
                if let text = barcode.payloadStringValue, onText(text) {
                    done = true
                    scanner.stopScanning()
                    return
                }
            }
        }
    }
}

#Preview {
    // No camera in the canvas or the simulator: this shows the sheet's chrome over a blank scanner.
    Text("Join")
        .sheet(isPresented: .constant(true)) { QRScannerView { _ in } }
}
