import SwiftUI
import ARKit
import RealityKit

struct ARCameraView: View {
    @StateObject private var arManager = ARCameraManager()
    @ObservedObject var location:  LocationService
    let onCapture: (CapturedPhoto) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isCapturing  = false
    @State private var showBurstHint = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // ARKit live preview
            ARViewRepresentable(session: arManager.session)
                .ignoresSafeArea()

            VStack {
                // ── Top bar ──
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.title2)
                            .foregroundColor(.white)
                            .padding(12)
                            .background(Circle().fill(Color.black.opacity(0.5)))
                    }
                    Spacer()
                    modeBadge
                }
                .padding()

                Spacer()

                if showBurstHint {
                    Text("Hold still… capturing depth frames")
                        .font(.caption.bold())
                        .foregroundColor(.white)
                        .padding(8)
                        .background(Capsule().fill(Color.black.opacity(0.6)))
                        .transition(.opacity)
                }

                // ── Heading display ──
                if let h = location.headingDegrees {
                    Text(String(format: "↑ %.0f°", h))
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.white.opacity(0.8))
                        .padding(.bottom, 6)
                }

                // ── Shutter ──
                Button(action: fireShutter) {
                    ZStack {
                        Circle()
                            .stroke(Color.white, lineWidth: isCapturing ? 4 : 3)
                            .frame(width: 72, height: 72)
                        if isCapturing {
                            ProgressView()
                                .tint(.white)
                                .scaleEffect(1.4)
                        } else {
                            Circle()
                                .fill(Color.white)
                                .frame(width: 60, height: 60)
                        }
                    }
                }
                .disabled(isCapturing)
                .padding(.bottom, 8)

                Text(isCapturing
                     ? "Collecting burst frames…"
                     : "Tap to capture photo + depth")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.7))
                    .padding(.bottom, 40)

                if let err = arManager.errorMessage {
                    Text(err)
                        .font(.caption)
                        .foregroundColor(.red)
                        .padding(.bottom, 8)
                }
            }
        }
        .onAppear {
            arManager.setup()
            location.requestPermissionAndStart()
        }
        .onDisappear { arManager.pause() }
        .onChange(of: arManager.isCapturing) { _, capturing in
            withAnimation { isCapturing = capturing }
        }
    }

    // MARK: - Helpers

    private var modeBadge: some View {
        Group {
            if location.coordinate != nil {
                Label("Outdoor · GPS", systemImage: "location.fill")
                    .foregroundColor(.green)
            } else {
                Label("Indoor · LiDAR", systemImage: "dot.radiowaves.right")
                    .foregroundColor(.cyan)
            }
        }
        .font(.caption.bold())
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color.black.opacity(0.5)))
        .foregroundColor(.white)
    }

    private func fireShutter() {
        withAnimation { showBurstHint = true }
        let (coord, heading) = location.snapshot()
        arManager.capturePhoto(location: (coord, heading)) { photo in
            withAnimation { showBurstHint = false }
            guard let photo else { return }
            onCapture(photo)
        }
    }
}

// MARK: - ARView wrapper for SwiftUI

private struct ARViewRepresentable: UIViewRepresentable {
    let session: ARSession

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero, cameraMode: .ar,
                          automaticallyConfigureSession: false)
        view.session = session
        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {}
}
