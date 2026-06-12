import UIKit
import simd

/// Fills disocclusion holes using the burst frames captured alongside the
/// main photo. Each burst frame has a known ARKit pose (world transform),
/// so we can reproject its pixels into the main camera's frame and paint
/// over any hole where we have real measured data.
///
/// This replaces Street View for indoor shots: instead of fetching an
/// external reference, we use the user's own frames taken 0.1–1 s earlier
/// from slightly different positions due to natural hand movement.
struct IndoorGroundingService {

    struct FillResult {
        let filled:      UIImage   // warped image with as many holes filled as possible
        let residualMask: UIImage  // remaining holes after burst fill (for Nano Banana)
        let filledPercent: Double  // how much of the original hole mask was covered
    }

    /// Try to fill `holeMask` in `warped` using the burst frames.
    /// - Parameters:
    ///   - warped:     Stage-1 output (black pixels at holes)
    ///   - holeMask:   White = hole, black = valid (from ReprojectionEngine)
    ///   - burstFrames: Frames captured ~1 s after main shutter
    ///   - mainTransform: ARKit world transform of the main frame
    ///   - yawDeg:     Angle applied in Stage 1 (so we transform into the same virtual cam)
    ///   - fovDeg:     Camera FOV
    ///   - orbitDist:  Orbit pivot distance
    func fill(
        warped:        UIImage,
        holeMask:      UIImage,
        burstFrames:   [ARBurstFrame],
        mainTransform: simd_float4x4,
        yawDeg:        Float,
        fovDeg:        Float = 70.0,
        orbitDist:     Float
    ) -> FillResult {

        guard !burstFrames.isEmpty,
              let holePixels = maskToArray(holeMask),
              var warpedPixels = imageToRGBA(warped) else {
            return FillResult(filled: warped, residualMask: holeMask, filledPercent: 0)
        }

        let W = ReprojectionEngine.procW
        let H = ReprojectionEngine.procH
        var remaining = holePixels

        // Process each burst frame: reproject it into the *virtual* camera space
        // (same transform used in stage 1), then paint holes
        for frame in burstFrames {
            guard let depth = frame.depth else { continue }

            // Relative pose: burst frame relative to main frame
            let relTransform = simd_inverse(mainTransform) * frame.transform

            // Reproject burst frame into virtual (post-rotation) camera space
            let bursts = reprojectBurst(
                burstImage: frame.image,
                burstDepth: depth,
                burstSize:  frame.imageSize,
                relPose:    relTransform,
                yawDeg:     yawDeg,
                fovDeg:     fovDeg,
                orbitDist:  orbitDist,
                outW: W, outH: H
            )
            guard let (burstR, burstG, burstB, burstValid) = bursts else { continue }

            // Paint over holes where burst provides valid data
            var filled = 0
            for i in 0..<(W * H) {
                if remaining[i] && burstValid[i] {
                    warpedPixels[i * 4]     = burstR[i]
                    warpedPixels[i * 4 + 1] = burstG[i]
                    warpedPixels[i * 4 + 2] = burstB[i]
                    remaining[i]             = false
                    filled += 1
                }
            }
            let stillHoles = remaining.filter { $0 }.count
            if stillHoles == 0 { break }
        }

        let totalHoles    = holePixels.filter { $0 }.count
        let residualHoles = remaining.filter  { $0 }.count
        let filledPct     = totalHoles > 0
            ? 100.0 * Double(totalHoles - residualHoles) / Double(totalHoles)
            : 0.0

        let size         = warped.size
        let filledImage  = makeImage(pixels: warpedPixels, w: W, h: H, targetSize: size)
        let residualMask = makeMask(holes: remaining, w: W, h: H, targetSize: size)

        return FillResult(filled: filledImage,
                          residualMask: residualMask,
                          filledPercent: filledPct)
    }

    // MARK: - Private

    private func reprojectBurst(
        burstImage: UIImage, burstDepth: [Float], burstSize: CGSize,
        relPose: simd_float4x4,
        yawDeg: Float, fovDeg: Float, orbitDist: Float,
        outW: Int, outH: Int
    ) -> ([UInt8], [UInt8], [UInt8], [Bool])? {

        let Wf = Float(outW), Hf = Float(outH)
        let fx = (Wf / 2) / tan(fovDeg * .pi / 360)
        let cx = Wf / 2, cy = Hf / 2

        // Virtual camera rotation (same as stage 1)
        let Rvirt  = rotY(yawDeg)
        let pivot  = SIMD3<Float>(0, 0, orbitDist)
        let Cvirt  = pivot - Rvirt * SIMD3<Float>(0, 0, orbitDist)

        // Burst camera pose relative to main
        let Rburst = simd_float3x3(relPose)
        let Cburst = SIMD3<Float>(relPose.columns.3.x,
                                   relPose.columns.3.y,
                                   relPose.columns.3.z)

        guard let srcPixels = resizedPixels(burstImage, w: outW, h: outH),
              let srcDepth  = resizeDepth(burstDepth,
                                          srcW: Int(burstSize.width),
                                          srcH: Int(burstSize.height),
                                          dstW: outW, dstH: outH) else {
            return nil
        }

        var zbuf   = [Float](repeating: .infinity, count: outW * outH)
        var outR   = [UInt8](repeating: 0, count: outW * outH)
        var outG   = [UInt8](repeating: 0, count: outW * outH)
        var outB   = [UInt8](repeating: 0, count: outW * outH)
        var valid  = [Bool](repeating: false, count: outW * outH)

        for row in 0..<outH {
            for col in 0..<outW {
                let idx = row * outW + col
                let d   = srcDepth[idx]
                guard d > 0.05 else { continue }

                // Back-project burst pixel to burst camera frame
                let pBurst = SIMD3<Float>(
                    (Float(col) - cx) / fx * d,
                    (Float(row) - cy) / fy * d,
                    d
                )

                // Transform: burst cam → world (via relPose) → main cam → virtual cam
                let pWorld = Rburst * pBurst + Cburst
                let pMain  = pWorld  // main cam IS the world origin
                let diff   = pMain - Cvirt
                let pVirt  = SIMD3<Float>(dot(Rvirt.columns.0, diff),
                                           dot(Rvirt.columns.1, diff),
                                           dot(Rvirt.columns.2, diff))
                guard pVirt.z > 0.05 else { continue }

                let u2 = fx * pVirt.x / pVirt.z + cx
                let v2 = fy * pVirt.y / pVirt.z + cy  // note: fy == fx here

                for du in 0...1 {
                    for dv in 0...1 {
                        let ui = Int(u2.rounded(.down)) + du
                        let vi = Int(v2.rounded(.down)) + dv
                        guard ui >= 0, ui < outW, vi >= 0, vi < outH else { continue }
                        let oi = vi * outW + ui
                        if pVirt.z < zbuf[oi] * 1.002 {
                            zbuf[oi]  = pVirt.z
                            outR[oi]  = srcPixels[idx * 4]
                            outG[oi]  = srcPixels[idx * 4 + 1]
                            outB[oi]  = srcPixels[idx * 4 + 2]
                            valid[oi] = true
                        }
                    }
                }
            }
        }
        return (outR, outG, outB, valid)
    }

    // MARK: - Math helpers

    private let fy: Float = 0  // unused — fy == fx for pinhole

    private func rotY(_ deg: Float) -> simd_float3x3 {
        let t = deg * .pi / 180; let c = cos(t), s = sin(t)
        return simd_float3x3(columns: (SIMD3(c,0,-s), SIMD3(0,1,0), SIMD3(s,0,c)))
    }

    private func simd_float3x3(_ m: simd_float4x4) -> simd_float3x3 {
        simd_float3x3(
            SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z),
            SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z),
            SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z)
        )
    }

    // MARK: - Pixel helpers (mirrors ReprojectionEngine private helpers)

    private func resizedPixels(_ img: UIImage, w: Int, h: Int) -> [UInt8]? {
        let cs  = CGColorSpaceCreateDeviceRGB()
        let bmi = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: cs, bitmapInfo: bmi.rawValue),
              let cg = img.cgImage else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return nil }
        let ptr = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        return Array(UnsafeBufferPointer(start: ptr, count: w * h * 4))
    }

    private func resizeDepth(_ src: [Float], srcW: Int, srcH: Int,
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

    private func imageToRGBA(_ img: UIImage) -> [UInt8]? {
        let w = ReprojectionEngine.procW, h = ReprojectionEngine.procH
        return resizedPixels(img, w: w, h: h)
    }

    private func maskToArray(_ mask: UIImage) -> [Bool]? {
        let w = ReprojectionEngine.procW, h = ReprojectionEngine.procH
        guard let px = resizedPixels(mask, w: w, h: h) else { return nil }
        return (0..<(w * h)).map { px[$0 * 4] > 128 }
    }

    private func makeImage(pixels: [UInt8], w: Int, h: Int,
                            targetSize: CGSize) -> UIImage {
        var px = pixels
        let cs  = CGColorSpaceCreateDeviceRGB()
        let bmi = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let provider = CGDataProvider(data: NSData(bytes: &px, length: px.count)),
              let cg = CGImage(width: w, height: h, bitsPerComponent: 8,
                                bitsPerPixel: 32, bytesPerRow: w * 4, space: cs,
                                bitmapInfo: bmi, provider: provider, decode: nil,
                                shouldInterpolate: false, intent: .defaultIntent) else {
            return UIImage()
        }
        let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1
        return UIGraphicsImageRenderer(size: targetSize, format: fmt).image { _ in
            UIImage(cgImage: cg).draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }

    private func makeMask(holes: [Bool], w: Int, h: Int,
                           targetSize: CGSize) -> UIImage {
        var px = [UInt8](repeating: 0, count: w * h * 4)
        for i in 0..<(w * h) {
            let v: UInt8 = holes[i] ? 255 : 0
            px[i * 4] = v; px[i * 4 + 1] = v; px[i * 4 + 2] = v; px[i * 4 + 3] = 255
        }
        return makeImage(pixels: px, w: w, h: h, targetSize: targetSize)
    }
}
