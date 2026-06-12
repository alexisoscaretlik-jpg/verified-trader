import UIKit
import CoreLocation

/// Fetches a Google Street View reference image at a given GPS coordinate and heading.
/// Used to give Nano Banana 2 spatial context when synthesizing a new camera angle.
struct StreetViewService {

    enum StreetViewError: LocalizedError {
        case noDataAvailable
        case httpError(Int)
        case invalidImage

        var errorDescription: String? {
            switch self {
            case .noDataAvailable: return "No Street View imagery at this location."
            case .httpError(let code): return "Street View API returned HTTP \(code)."
            case .invalidImage: return "Street View returned unreadable image data."
            }
        }
    }

    /// Returns a Street View JPEG for `coordinate` looking in `heading` direction.
    /// - Parameters:
    ///   - coordinate: GPS position (from phone at capture time)
    ///   - heading: compass heading in degrees 0–360 (0 = North)
    ///   - pitch: vertical angle in degrees; 0 = horizon, positive = up
    ///   - size: pixel size of the returned image (width x height)
    func fetchReferenceImage(
        at coordinate: CLLocationCoordinate2D,
        heading: Double,
        pitch: Double = 0,
        size: CGSize = CGSize(width: 640, height: 480)
    ) async throws -> UIImage {

        var components = URLComponents(string: Config.streetViewURL)!
        components.queryItems = [
            URLQueryItem(name: "size",    value: "\(Int(size.width))x\(Int(size.height))"),
            URLQueryItem(name: "location",value: "\(coordinate.latitude),\(coordinate.longitude)"),
            URLQueryItem(name: "heading", value: String(format: "%.1f", normalizeHeading(heading))),
            URLQueryItem(name: "pitch",   value: String(format: "%.1f", pitch.clamped(to: -90...90))),
            URLQueryItem(name: "fov",     value: "90"),
            URLQueryItem(name: "key",     value: Config.mapsAPIKey)
        ]

        let url = components.url!
        let (data, response) = try await URLSession.shared.data(from: url)

        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw StreetViewError.httpError(http.statusCode)
        }
        guard let image = UIImage(data: data) else {
            throw StreetViewError.invalidImage
        }

        // Street View returns a gray "no imagery" image when coverage is absent;
        // detect it by checking if image is predominantly gray.
        if isNoImageryPlaceholder(image) {
            throw StreetViewError.noDataAvailable
        }
        return image
    }

    // MARK: - Helpers

    private func normalizeHeading(_ h: Double) -> Double {
        var result = h.truncatingRemainder(dividingBy: 360)
        if result < 0 { result += 360 }
        return result
    }

    /// Heuristic: the Street View "no coverage" gray placeholder has very low color variance.
    private func isNoImageryPlaceholder(_ image: UIImage) -> Bool {
        guard let cgImage = image.cgImage else { return false }
        let size = 10
        let ctx = CGContext(data: nil, width: size, height: size,
                            bitsPerComponent: 8, bytesPerRow: size * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(cgImage, in: CGRect(origin: .zero, size: CGSize(width: size, height: size)))
        guard let data = ctx.data else { return false }
        let ptr = data.bindMemory(to: UInt8.self, capacity: size * size * 4)
        var rSum = 0, gSum = 0, bSum = 0
        for i in 0..<(size * size) {
            rSum += Int(ptr[i * 4])
            gSum += Int(ptr[i * 4 + 1])
            bSum += Int(ptr[i * 4 + 2])
        }
        let n = size * size
        let rAvg = rSum / n, gAvg = gSum / n, bAvg = bSum / n
        // All channels nearly equal and mid-range → gray placeholder
        return abs(rAvg - gAvg) < 8 && abs(gAvg - bAvg) < 8 && rAvg > 150 && rAvg < 220
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
