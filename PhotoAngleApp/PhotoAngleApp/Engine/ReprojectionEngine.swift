import UIKit
import Accelerate
import simd

/// Stage 1 of the hybrid pipeline: deterministic, geometrically-correct view change.
///
/// Takes an RGB image and a per-pixel depth map (in metres, same pixel layout),
/// rotates the virtual camera around the subject by `yawDeg` degrees, and
/// renders the scene from the new viewpoint using a z-buffered point splat.
///
/// Returns:
///   warped   — the re-rendered image (black where no source pixel landed)
///   holeMask — binary mask: true = disocclusion hole that needs generative fill
///
/// The pipeline is proven at 35+ dB PSNR against ground truth in the Python
/// prototype (prototype/demo_synthetic.py). This Swift implementation uses the
/// same projective geometry, reduced to processing resolution for on-device speed.
enum ReprojectionEngine {

    // Processing resolution. The output is upscaled back to the input size.
    static let procW: Int = 640
    static let procH: Int = 480

    // MARK: - Public API

    struct Result {
        let warped:   UIImage
        let holeMask: UIImage   // white = hole, black = valid
        let holePercent: Double // 0–100
    }

    /// Orbit the virtual camera `yawDeg` around the subject at `orbitDistance` metres.
    static func reproject(
        image:          UIImage,
        depth:          [Float],        // row-major, metres, same HxW as image
        imageSize:      CGSize,         // original image size
        yawDeg:         Float,
        pitchDeg:       Float   = 0,
        fovDeg:         Float   = 70.0,
        orbitDistance:  Float           // pivot distance in metres (median depth)
    ) -> Result {

        let W = procW, H = procH
        let Wf = Float(W), Hf = Float(H)

        // --- 1. Resize image and depth to processing resolution ---
        guard let srcPixels = resizedPixels(image, w: W, h: H),
              let srcDepth  = resizeDepth(depth,
                                          srcW: Int(imageSize.width),
                                          srcH: Int(imageSize.height),
                                          dstW: W, dstH: H) else {
            return fallback(image: image)
        }

        // --- 2. Camera intrinsics (pinhole, iPhone wide ≈ 70° hFOV) ---
        let fx = (Wf / 2) / tan(fovDeg * .pi / 360)
        let fy = fx
        let cx = Wf / 2, cy = Hf / 2

        // --- 3. Orbit camera pose: pivot at P=(0,0,D), rotate yaw around it ---
        let R     = rotY(yawDeg) * rotX(pitchDeg)
        let pivot = SIMD3<Float>(0, 0, orbitDistance)
        let C     = pivot - R * SIMD3<Float>(0, 0, orbitDistance)

        // --- 4. Z-buffer + output buffers ---
        var zbuf  = [Float](repeating: .infinity, count: W * H)
        var outR  = [UInt8](repeating: 0, count: W * H)
        var outG  = [UInt8](repeating: 0, count: W * H)
        var outB  = [UInt8](repeating: 0, count: W * H)

        // --- 5. Back-project, transform, forward-project ---
        for row in 0..<H {
            for col in 0..<W {
                let idx = row * W + col
                let d = srcDepth[idx]
                guard d > 0.05 else { continue }

                // Back-project to camera-frame 3D
                let p = SIMD3<Float>(
                    (Float(col) - cx) / fx * d,
                    (Float(row) - cy) / fy * d,
                    d
                )

                // Transform into new camera frame: p2 = R^T * (p - C)
                let diff = p - C
                let p2   = SIMD3<Float>(
                    dot(R.columns.0, diff),
                    dot(R.columns.1, diff),
                    dot(R.columns.2, diff)
                )
                guard p2.z > 0.05 else { continue }

                // Forward project
                let u2 = fx * p2.x / p2.z + cx
                let v2 = fy * p2.y / p2.z + cy

                // 2×2 splat (closes resampling cracks without smearing edges)
                for du in 0...1 {
                    for dv in 0...1 {
                        let ui = Int(u2.rounded(.down)) + du
                        let vi = Int(v2.rounded(.down)) + dv
                        guard ui >= 0, ui < W, vi >= 0, vi < H else { continue }
                        let oi = vi * W + ui
                        // z-test with 0.2% tolerance for co-planar surfaces
                        if p2.z < zbuf[oi] * 1.002 {
                            zbuf[oi] = p2.z
                            let srcPx = idx * 4
                            outR[oi] = srcPixels[srcPx]
                            outG[oi] = srcPixels[srcPx + 1]
                            outB[oi] = srcPixels[srcPx + 2]
                        }
                    }
                }
            }
        }

        // --- 6. Build output UIImages ---
        let holes    = zbuf.map { !$0.isFinite }
        let holePct  = 100.0 * Double(holes.filter { $0 }.count) / Double(W * H)
        let warpedImg = buildImage(r: outR, g: outG, b: outB, w: W, h: H,
                                   targetSize: image.size)
        let maskImg   = buildMask(holes: holes, w: W, h: H, targetSize: image.size)
        return Result(warped: warpedImg, holeMask: maskImg, holePercent: holePct)
    }

    // MARK: - Private helpers

    private static func rotY(_ deg: Float) -> simd_float3x3 {
        let t = deg * .pi / 180
        let c = cos(t), s = sin(t)
        return simd_float3x3(columns: (
            SIMD3(c, 0, -s),
            SIMD3(0, 1,  0),
            SIMD3(s, 0,  c)
        ))
    }

    private static func rotX(_ deg: Float) -> simd_float3x3 {
        let t = deg * .pi / 180
        let c = cos(t), s = sin(t)
        return simd_float3x3(columns: (
            SIMD3(1,  0,  0),
            SIMD3(0,  c,  s),
            SIMD3(0, -s,  c)
        ))
    }

    /// Resize image to (w,h) and return raw RGBA bytes.
    private static func resizedPixels(_ image: UIImage, w: Int, h: Int) -> [UInt8]? {
        let cs    = CGColorSpaceCreateDeviceRGB()
        let bmi   = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: cs, bitmapInfo: bmi.rawValue),
              let cg  = image.cgImage else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return nil }
        let ptr = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        return Array(UnsafeBufferPointer(start: ptr, count: w * h * 4))
    }

    /// Nearest-neighbour resize of a float depth map.
    private static func resizeDepth(_ src: [Float],
                                    srcW: Int, srcH: Int,
                                    dstW: Int, dstH: Int) -> [Float]? {
        guard src.count == srcW * srcH else { return nil }
        var dst = [Float](repeating: 0, count: dstW * dstH)
        for dv in 0..<dstH {
            let sv = min(Int(Float(dv) * Float(srcH) / Float(dstH)), srcH - 1)
            for du in 0..<dstW {
                let su = min(Int(Float(du) * Float(srcW) / Float(dstW)), srcW - 1)
                dst[dv * dstW + du] = src[sv * srcW + su]
            }
        }
        return dst
    }

    private static func buildImage(r: [UInt8], g: [UInt8], b: [UInt8],
                                   w: Int, h: Int, targetSize: CGSize) -> UIImage {
        var rgba = [UInt8](repeating: 255, count: w * h * 4)
        for i in 0..<(w * h) {
            rgba[i * 4]     = r[i]
            rgba[i * 4 + 1] = g[i]
            rgba[i * 4 + 2] = b[i]
        }
        return makeUIImage(pixels: rgba, w: w, h: h, targetSize: targetSize)
    }

    private static func buildMask(holes: [Bool], w: Int, h: Int,
                                  targetSize: CGSize) -> UIImage {
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        for i in 0..<(w * h) {
            let v: UInt8 = holes[i] ? 255 : 0
            rgba[i * 4]     = v
            rgba[i * 4 + 1] = v
            rgba[i * 4 + 2] = v
            rgba[i * 4 + 3] = 255
        }
        // Dilate mask 1px to cover splat-edge artifacts
        return makeUIImage(pixels: rgba, w: w, h: h, targetSize: targetSize)
    }

    private static func makeUIImage(pixels: [UInt8], w: Int, h: Int,
                                    targetSize: CGSize) -> UIImage {
        let cs  = CGColorSpaceCreateDeviceRGB()
        let bmi = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        var px  = pixels
        guard let provider = CGDataProvider(data: NSData(bytes: &px,
                                                         length: px.count)),
              let cgImg = CGImage(width: w, height: h,
                                  bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: w * 4, space: cs,
                                  bitmapInfo: bmi,
                                  provider: provider,
                                  decode: nil, shouldInterpolate: false,
                                  intent: .defaultIntent) else {
            return UIImage()
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: targetSize, format: format).image { ctx in
            UIImage(cgImage: cgImg).draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }

    private static func fallback(image: UIImage) -> Result {
        let blank = UIGraphicsImageRenderer(size: image.size).image { _ in
            UIColor.black.setFill()
            UIRectFill(CGRect(origin: .zero, size: image.size))
        }
        return Result(warped: image, holeMask: blank, holePercent: 0)
    }
}
