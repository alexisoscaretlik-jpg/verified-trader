import UIKit
import Foundation

/// Calls Nano Banana 2 (Gemini 2.5 Flash Image) in two modes:
///
///   .inpaint  — Hybrid Stage 2: fills the hole mask only. The geometrically
///               correct pixels are untouched; only the disocclusion holes
///               (where no 3D data existed) get generative fill.
///               Optional reference image (Street View outdoor / burst-composite
///               indoor) constrains the fill to match the real scene.
///
///   .fullShift — Legacy fallback for photos with NO depth data (non-Pro iPhone,
///               no LiDAR). Full angle change from scratch via prompt only.
struct NanoBananaService {

    enum Mode {
        case inpaint   // hybrid stage 2: fill holes in an already-reprojected image
        case fullShift // no depth available — ask Nano Banana to do the whole thing
    }

    enum NBError: LocalizedError {
        case encodingFailed
        case networkError(Error)
        case apiError(Int, String)
        case noImageInResponse
        var errorDescription: String? {
            switch self {
            case .encodingFailed:          return "Could not encode image."
            case .networkError(let e):     return "Network: \(e.localizedDescription)"
            case .apiError(let c, let m):  return "Nano Banana API \(c): \(m)"
            case .noImageInResponse:       return "Nano Banana returned no image."
            }
        }
    }

    // MARK: - Inpaint mode (hybrid stage 2)

    /// Fill disocclusion holes in `warped` at pixels marked by `holeMask`.
    /// - Parameters:
    ///   - warped:    Stage-1 reprojected image (geometrically correct, black holes)
    ///   - holeMask:  White = hole to fill, black = do not touch
    ///   - reference: Street View panorama (outdoor) or burst composite (indoor)
    ///   - degrees:   Angle applied in stage 1 (for context in the prompt)
    ///   - isIndoor:  True → reference is a burst composite; false → Street View
    func inpaintHoles(
        warped:    UIImage,
        holeMask:  UIImage,
        reference: UIImage?,
        degrees:   Double,
        isIndoor:  Bool
    ) async throws -> UIImage {
        guard let warpedData = warped.jpegData(compressionQuality: 0.90),
              let maskData   = holeMask.pngData() else { throw NBError.encodingFailed }

        var parts: [[String: Any]] = [
            ["text": inpaintPrompt(degrees: degrees, isIndoor: isIndoor,
                                   hasReference: reference != nil)],
            ["inline_data": ["mime_type": "image/jpeg",
                             "data": warpedData.base64EncodedString()]],
            ["inline_data": ["mime_type": "image/png",
                             "data": maskData.base64EncodedString()]]
        ]

        if let ref = reference, let refData = ref.jpegData(compressionQuality: 0.85) {
            parts.append(["inline_data": ["mime_type": "image/jpeg",
                                          "data": refData.base64EncodedString()]])
        }

        return try await callAPI(parts: parts)
    }

    // MARK: - Full-shift mode (no LiDAR fallback)

    func fullShift(
        photo:       UIImage,
        degrees:     Double,
        direction:   AngleDirection,
        streetView:  UIImage?
    ) async throws -> UIImage {
        guard let photoData = photo.jpegData(compressionQuality: 0.85) else {
            throw NBError.encodingFailed
        }
        var parts: [[String: Any]] = [
            ["text": fullShiftPrompt(degrees: degrees, direction: direction,
                                     hasReference: streetView != nil)],
            ["inline_data": ["mime_type": "image/jpeg",
                             "data": photoData.base64EncodedString()]]
        ]
        if let sv = streetView, let svd = sv.jpegData(compressionQuality: 0.80) {
            parts.append(["inline_data": ["mime_type": "image/jpeg",
                                          "data": svd.base64EncodedString()]])
        }
        return try await callAPI(parts: parts)
    }

    // MARK: - Prompts

    private func inpaintPrompt(degrees: Double, isIndoor: Bool, hasReference: Bool) -> String {
        var p = """
        Image 1 is a photo whose camera has been geometrically rotated \
        \(Int(degrees))° using real depth data — every VISIBLE pixel is already \
        geometrically correct. Image 2 is a binary mask: pure WHITE marks \
        disocclusion holes where no 3D data existed.
        Task: fill ONLY the white-masked regions with photorealistic scene \
        content. Do NOT alter any pixel outside the mask. Match the lighting, \
        colour grading, and texture style of the unmasked area exactly.
        """
        if hasReference {
            let src = isIndoor
                ? "a real photo from an adjacent camera position of the same space"
                : "a Google Street View panorama from the same GPS location"
            p += " Image 3 is \(src) — use it as ground-truth for the occluded geometry."
        }
        return p
    }

    private func fullShiftPrompt(degrees: Double, direction: AngleDirection,
                                  hasReference: Bool) -> String {
        var p = """
        Re-render Image 1 as if the camera orbited the subject \(Int(degrees))° \
        \(direction.rawValue.lowercased()). Keep lighting and colour grading \
        identical. Synthesise occluded areas photorealistically.
        """
        if hasReference {
            p += " Image 2 is a Google Street View reference at the target angle — \
        use it for accurate scene geometry."
        }
        return p
    }

    // MARK: - API call

    private func callAPI(parts: [[String: Any]]) async throws -> UIImage {
        let body: [String: Any] = [
            "contents": [["role": "user", "parts": parts]],
            "generationConfig": [
                "responseModalities": ["Text", "Image"],
                "temperature": 1.0
            ]
        ]

        let url = URL(string:
            "\(Config.geminiBaseURL)/\(Config.nanoBananaModel):generateContent?key=\(Config.geminiAPIKey)"
        )!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody   = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 90

        let (data, response): (Data, URLResponse)
        do { (data, response) = try await URLSession.shared.data(for: req) }
        catch { throw NBError.networkError(error) }

        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw NBError.apiError(http.statusCode,
                                   String(data: data, encoding: .utf8) ?? "")
        }
        return try extractImage(from: data)
    }

    private func extractImage(from data: Data) throws -> UIImage {
        guard let json  = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cands = json["candidates"] as? [[String: Any]],
              let first  = cands.first,
              let cont   = first["content"] as? [String: Any],
              let parts  = cont["parts"] as? [[String: Any]] else {
            throw NBError.noImageInResponse
        }
        for part in parts {
            let id = part["inline_data"] ?? part["inlineData"]
            if let id = id as? [String: Any],
               let b64 = id["data"] as? String,
               let imgData = Data(base64Encoded: b64),
               let img = UIImage(data: imgData) { return img }
        }
        throw NBError.noImageInResponse
    }
}
