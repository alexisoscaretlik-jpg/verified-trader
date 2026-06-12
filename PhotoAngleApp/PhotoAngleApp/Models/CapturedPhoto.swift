import UIKit
import CoreLocation

struct CapturedPhoto: Identifiable {
    let id = UUID()
    let image: UIImage
    let coordinate: CLLocationCoordinate2D?  // nil if GPS unavailable
    let headingDegrees: Double?              // compass heading at capture, 0–360
    let capturedAt: Date

    var hasGPS: Bool { coordinate != nil }
}

/// Direction the user wants to shift the virtual camera.
enum AngleDirection: String, CaseIterable {
    case left  = "Left"
    case right = "Right"
    case up    = "Up"
    case down  = "Down"

    var streetViewHeadingOffset: Double {
        switch self {
        case .left:  return -1.0   // multiplied by degrees slider
        case .right: return  1.0
        case .up, .down: return 0  // pitch-only change
        }
    }

    var streetViewPitchOffset: Double {
        switch self {
        case .up:    return  1.0
        case .down:  return -1.0
        case .left, .right: return 0
        }
    }
}

struct AngleCorrectionRequest {
    let photo: CapturedPhoto
    let degrees: Double          // 15 – 50
    let direction: AngleDirection
}

struct AngleCorrectionResult: Identifiable {
    let id = UUID()
    let original: UIImage
    let corrected: UIImage
    let streetViewReference: UIImage?
    let degreesApplied: Double
    let direction: AngleDirection
}
