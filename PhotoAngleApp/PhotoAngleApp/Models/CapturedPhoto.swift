import UIKit
import CoreLocation
import ARKit

// A single captured frame from ARKit, used as a burst reference for indoor grounding.
struct ARBurstFrame {
    let image:     UIImage
    let depth:     [Float]?          // row-major metres, may be nil on non-Pro
    let transform: simd_float4x4     // ARFrame.camera.transform (world pose)
    let imageSize: CGSize
}

struct CapturedPhoto: Identifiable {
    let id           = UUID()
    let image:         UIImage
    let imageSize:     CGSize

    // Depth: row-major array of metres, same layout as image pixels.
    // Populated from LiDAR (Pro iPhones) or nil (non-Pro, no depth capture).
    let depth:         [Float]?

    // Burst frames captured in the ~1 s after shutter — used to fill
    // disocclusion holes indoors without calling an external API.
    let burstFrames:   [ARBurstFrame]

    // GPS / compass (nil when indoors or permission denied)
    let coordinate:      CLLocationCoordinate2D?
    let headingDegrees:  Double?

    let capturedAt: Date

    // MARK: - Derived

    var hasLiDAR: Bool { depth != nil }
    var hasGPS:   Bool { coordinate != nil }

    /// True when GPS is unavailable or very inaccurate → treat as indoor.
    var isIndoor: Bool { !hasGPS }

    /// Best-effort orbit distance: median of the centre-region depth.
    var medianDepth: Float {
        guard let d = depth, !d.isEmpty else { return 4.0 }
        let w = Int(imageSize.width),  h = Int(imageSize.height)
        let x0 = w / 4, x1 = 3 * w / 4
        let y0 = h / 4, y1 = 3 * h / 4
        var centre: [Float] = []
        for row in y0..<y1 {
            for col in x0..<x1 {
                let v = d[row * w + col]
                if v > 0.1 { centre.append(v) }
            }
        }
        guard !centre.isEmpty else { return 4.0 }
        let sorted = centre.sorted()
        return sorted[sorted.count / 2]
    }
}

enum AngleDirection: String, CaseIterable {
    case left  = "Left"
    case right = "Right"
    case up    = "Up"
    case down  = "Down"

    var yawOffset: Float {
        switch self {
        case .left:  return -1
        case .right: return  1
        default:     return  0
        }
    }
    var pitchOffset: Float {
        switch self {
        case .up:   return  1
        case .down: return -1
        default:    return  0
        }
    }
}

struct AngleCorrectionResult: Identifiable {
    let id                = UUID()
    let original:           UIImage
    let corrected:          UIImage
    let streetViewReference:UIImage?
    let warpedWithHoles:    UIImage?   // stage-1 output (diagnostic)
    let holeMask:           UIImage?
    let holePercent:        Double
    let degreesApplied:     Double
    let direction:          AngleDirection
    let wasIndoor:          Bool
}
