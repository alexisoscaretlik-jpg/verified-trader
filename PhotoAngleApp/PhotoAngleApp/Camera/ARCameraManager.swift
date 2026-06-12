import ARKit
import UIKit
import Combine

/// Manages an ARKit WorldTracking session that captures:
///   - A full-resolution photo (via AVCapturePhotoOutput overlay)
///   - A per-pixel LiDAR depth map (via ARFrame.sceneDepth, Pro iPhones only)
///   - A burst of 5 auxiliary frames for indoor disocclusion filling
///
/// On non-Pro iPhones (no LiDAR), depth is nil and the app falls back to
/// calling Depth Pro on the server side (see NanoBananaService).
@MainActor
final class ARCameraManager: NSObject, ObservableObject {

    // MARK: - Published state

    @Published var session     = ARSession()
    @Published var isReady     = false
    @Published var isCapturing = false
    @Published var errorMessage: String?

    // MARK: - Capture request

    private var pendingCapture: ((CapturedPhoto?) -> Void)?
    private var burstBuffer:    [ARBurstFrame] = []
    private var mainFrame:      ARFrame?
    private var burstCountdown  = 0

    // MARK: - Setup

    func setup() {
        let config = ARWorldTrackingConfiguration()
        config.worldAlignment = .gravity

        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics.insert(.sceneDepth)
        }
        config.isAutoFocusEnabled = true
        session.delegate = self
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
        isReady = true
    }

    func pause() { session.pause() }

    // MARK: - Capture

    /// Press-and-hold: captures main frame + 5 burst frames (~1 s).
    func capturePhoto(
        location: (coordinate: CLLocationCoordinate2D?,
                   heading: Double?),
        completion: @escaping (CapturedPhoto?) -> Void
    ) {
        guard !isCapturing else { return }
        isCapturing   = true
        burstBuffer   = []
        mainFrame     = nil
        burstCountdown = 5        // collect 5 more frames after main
        pendingCapture = completion
    }

    // MARK: - Private helpers

    private func extractDepth(_ frame: ARFrame) -> [Float]? {
        guard let sceneDepth = frame.sceneDepth else { return nil }
        let depthMap = sceneDepth.depthMap       // CVPixelBuffer, Float32, metres

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

        let w    = CVPixelBufferGetWidth(depthMap)
        let h    = CVPixelBufferGetHeight(depthMap)
        let bpr  = CVPixelBufferGetBytesPerRow(depthMap)
        guard let base = CVPixelBufferGetBaseAddress(depthMap) else { return nil }

        var result = [Float](repeating: 0, count: w * h)
        for row in 0..<h {
            let src = base.advanced(by: row * bpr)
                          .bindMemory(to: Float32.self, capacity: w)
            for col in 0..<w {
                result[row * w + col] = src[col]
            }
        }
        return result
    }

    private func imageFromFrame(_ frame: ARFrame) -> (UIImage, CGSize) {
        let pb   = frame.capturedImage
        let ciImg = CIImage(cvPixelBuffer: pb)
        let ctx   = CIContext(options: [.useSoftwareRenderer: false])
        guard let cg = ctx.createCGImage(ciImg, from: ciImg.extent) else {
            return (UIImage(), .zero)
        }
        // ARKit returns landscape; rotate to portrait if phone is held upright
        let size   = CGSize(width: cg.width, height: cg.height)
        let uiImg  = UIImage(cgImage: cg,
                             scale: 1,
                             orientation: .right)  // 90° CCW for portrait
        let pSize  = CGSize(width: cg.height, height: cg.width)
        return (uiImg, pSize)
    }

    private func finalise(main: ARFrame,
                          burst: [ARBurstFrame],
                          loc: (CLLocationCoordinate2D?, Double?)) {
        let (image, size) = imageFromFrame(main)
        let depth         = extractDepth(main)

        let photo = CapturedPhoto(
            image:          image,
            imageSize:      size,
            depth:          depth,
            burstFrames:    burst,
            coordinate:     loc.0,
            headingDegrees: loc.1,
            capturedAt:     Date()
        )

        let cb = pendingCapture
        pendingCapture = nil
        isCapturing    = false
        cb?(photo)
    }
}

// MARK: - ARSessionDelegate

extension ARCameraManager: ARSessionDelegate {

    nonisolated func session(_ session: ARSession,
                             didUpdate frame: ARFrame) {
        Task { @MainActor in
            guard isCapturing else { return }

            if mainFrame == nil {
                // First frame after shutter tap = main frame
                mainFrame      = frame
                burstCountdown = 5
                return
            }

            if burstCountdown > 0 {
                let (img, sz) = imageFromFrame(frame)
                let dep       = extractDepth(frame)
                burstBuffer.append(ARBurstFrame(
                    image:     img,
                    depth:     dep,
                    transform: frame.camera.transform,
                    imageSize: sz
                ))
                burstCountdown -= 1

                if burstCountdown == 0, let main = mainFrame {
                    finalise(main: main, burst: burstBuffer, loc: (nil, nil))
                }
            }
        }
    }

    nonisolated func session(_ session: ARSession,
                             didFailWithError error: Error) {
        Task { @MainActor in
            errorMessage = error.localizedDescription
        }
    }
}
