import SwiftUI
import AVFoundation

/// Full-screen live camera preview with a capture button.
/// Records GPS + compass heading the moment the shutter fires.
struct CameraView: View {
    @StateObject private var camera   = CameraManager()
    @ObservedObject var location: LocationService
    let onCapture: (CapturedPhoto) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let layer = camera.previewLayer {
                CameraPreviewRepresentable(layer: layer)
                    .ignoresSafeArea()
            } else {
                ProgressView("Starting camera…")
                    .foregroundColor(.white)
            }

            VStack {
                // Top bar
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.title2)
                            .foregroundColor(.white)
                            .padding(12)
                            .background(Circle().fill(Color.black.opacity(0.5)))
                    }
                    Spacer()
                    if location.coordinate != nil {
                        Label("GPS", systemImage: "location.fill")
                            .font(.caption.bold())
                            .foregroundColor(.green)
                            .padding(6)
                            .background(Capsule().fill(Color.black.opacity(0.5)))
                    } else {
                        Label("No GPS", systemImage: "location.slash")
                            .font(.caption)
                            .foregroundColor(.orange)
                            .padding(6)
                            .background(Capsule().fill(Color.black.opacity(0.5)))
                    }
                }
                .padding()

                Spacer()

                // Heading indicator
                if let heading = location.headingDegrees {
                    Text(String(format: "↑ %.0f°", heading))
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.white.opacity(0.8))
                        .padding(.bottom, 8)
                }

                // Shutter button
                Button(action: fireShutter) {
                    ZStack {
                        Circle()
                            .stroke(Color.white, lineWidth: 3)
                            .frame(width: 72, height: 72)
                        Circle()
                            .fill(Color.white)
                            .frame(width: 60, height: 60)
                    }
                }
                .padding(.bottom, 40)

                if let err = camera.captureError {
                    Text(err)
                        .font(.caption)
                        .foregroundColor(.red)
                        .padding(.bottom, 8)
                }
            }
        }
        .onAppear {
            camera.setup()
            location.requestPermissionAndStart()
        }
        .onDisappear { camera.stopSession() }
    }

    private func fireShutter() {
        let (coord, heading) = location.snapshot()
        camera.capturePhoto { image in
            guard let image else { return }
            let photo = CapturedPhoto(
                image: image,
                coordinate: coord,
                headingDegrees: heading,
                capturedAt: Date()
            )
            onCapture(photo)
        }
    }
}

// AVCaptureVideoPreviewLayer wrapped for SwiftUI
private struct CameraPreviewRepresentable: UIViewRepresentable {
    let layer: AVCaptureVideoPreviewLayer

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black
        layer.frame = view.bounds
        view.layer.addSublayer(layer)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        layer.frame = uiView.bounds
    }
}
