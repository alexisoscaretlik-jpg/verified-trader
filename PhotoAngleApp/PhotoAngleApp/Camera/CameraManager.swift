import AVFoundation
import UIKit
import Combine

@MainActor
final class CameraManager: NSObject, ObservableObject {
    @Published var previewLayer: AVCaptureVideoPreviewLayer?
    @Published var captureError: String?
    @Published var isReady = false

    private let session = AVCaptureSession()
    private let output  = AVCapturePhotoOutput()
    private var captureCompletion: ((UIImage?) -> Void)?

    // Runs setup off main thread to avoid blocking UI
    func setup() {
        Task.detached(priority: .userInitiated) { [weak self] in
            await self?.configureSession()
        }
    }

    func capturePhoto(completion: @escaping (UIImage?) -> Void) {
        captureCompletion = completion
        let settings = AVCapturePhotoSettings()
        settings.flashMode = .auto
        output.capturePhoto(with: settings, delegate: self)
    }

    func startSession() {
        Task.detached { [weak self] in
            self?.session.startRunning()
        }
    }

    func stopSession() {
        Task.detached { [weak self] in
            self?.session.stopRunning()
        }
    }

    // MARK: - Private

    private func configureSession() async {
        session.beginConfiguration()
        session.sessionPreset = .photo

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                   for: .video,
                                                   position: .back),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            await MainActor.run { captureError = "Camera not available." }
            return
        }
        session.addInput(input)

        guard session.canAddOutput(output) else {
            await MainActor.run { captureError = "Cannot configure photo output." }
            return
        }
        session.addOutput(output)
        session.commitConfiguration()

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill

        await MainActor.run {
            previewLayer = layer
            isReady = true
        }
        session.startRunning()
    }
}

extension CameraManager: AVCapturePhotoCaptureDelegate {
    nonisolated func photoOutput(_ output: AVCapturePhotoOutput,
                                 didFinishProcessingPhoto photo: AVCapturePhoto,
                                 error: Error?) {
        Task { @MainActor in
            guard error == nil,
                  let data = photo.fileDataRepresentation(),
                  let image = UIImage(data: data) else {
                captureCompletion?(nil)
                captureCompletion = nil
                return
            }
            captureCompletion?(image)
            captureCompletion = nil
        }
    }
}
