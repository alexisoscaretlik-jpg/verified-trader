import UIKit
import Foundation

/// Calls Google's Nano Banana 2 (Gemini 2.5 Flash Image) to synthesize a
/// new camera angle from the user's photo, optionally guided by a Street View
/// reference image when GPS data is available.
///
/// Pipeline:
///   1. Encode user photo as base64 JPEG
///   2. (If available) Encode Street View reference as base64 JPEG
///   3. Build a structured prompt specifying exact angle change in degrees
///   4. POST to Gemini generateContent with responseModalities: ["Text","Image"]
///   5. Decode the returned inline_data image
struct NanoBananaService {

    enum NBError: LocalizedError {
        case encodingFailed
        case networkError(Error)
        case apiError(Int, String)
        case noImageInResponse
        case decodingFailed

        var errorDescription: String? {
            switch self {
            case .encodingFailed:        return "Could not encode image for upload."
            case .networkError(let e):   return "Network error: \(e.localizedDescription)"
            case .apiError(let c, let m):return "Nano Banana API error \(c): \(m)"
            case .noImageInResponse:     return "Nano Banana did not return an image. Try a smaller angle or a different photo."
            case .decodingFailed:        return "Could not decode the AI-generated image."
            }
        }
    }

    /// Sends the photo (+ optional Street View reference) to Nano Banana 2.
    /// Returns the angle-corrected image.
    func correctAngle(
        photo: UIImage,
        degrees: Double,
        direction: AngleDirection,
        streetViewReference: UIImage? = nil
    ) async throws -> UIImage {

        guard let photoData = photo.jpegData(compressionQuality: 0.85) else {
            throw NBError.encodingFailed
        }
        let photoBase64 = photoData.base64EncodedString()

        let prompt = buildPrompt(degrees: degrees, direction: direction,
                                 hasReference: streetViewReference != nil)

        var parts: [[String: Any]] = [
            ["text": prompt],
            [
                "inline_data": [
                    "mime_type": "image/jpeg",
                    "data": photoBase64
                ]
            ]
        ]

        if let ref = streetViewReference,
           let refData = ref.jpegData(compressionQuality: 0.80) {
            parts.append([
                "inline_data": [
                    "mime_type": "image/jpeg",
                    "data": refData.base64EncodedString()
                ]
            ])
        }

        let body: [String: Any] = [
            "contents": [
                ["role": "user", "parts": parts]
            ],
            "generationConfig": [
                "responseModalities": ["Text", "Image"],
                "temperature": 1.0
            ]
        ]

        let url = URL(string: "\(Config.geminiBaseURL)/\(Config.nanoBananaModel):generateContent?key=\(Config.geminiAPIKey)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 90  // image generation can take up to ~60s

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw NBError.networkError(error)
        }

        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let detail = String(data: data, encoding: .utf8) ?? "no body"
            throw NBError.apiError(http.statusCode, detail)
        }

        return try extractImage(from: data)
    }

    // MARK: - Private

    private func buildPrompt(degrees: Double, direction: AngleDirection,
                             hasReference: Bool) -> String {
        let degStr = String(format: "%.0f", degrees)

        var prompt = """
        You are Nano Banana, Google's AI image editor.

        TASK: Re-render the FIRST image as if the camera had been physically moved \
        \(degStr) degrees \(direction.rawValue.lowercased()) from its original position. \
        Keep all subjects, lighting, and color grading identical — only the camera \
        viewpoint should change. Synthesize any newly-visible areas realistically.
        """

        if hasReference {
            prompt += """


        CONTEXT: The SECOND image is a Google Street View panorama captured at the \
        same GPS location. Use it to understand the scene geometry — building facades, \
        street layout, depth — so that newly-visible areas in the rotated view are \
        spatially accurate, not hallucinated.
        """
        }

        prompt += """


        OUTPUT: One photorealistic image only. No text overlays, no borders, \
        same aspect ratio and resolution as the input. Do not describe the image.
        """
        return prompt
    }

    private func extractImage(from data: Data) throws -> UIImage {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let first = candidates.first,
              let content = first["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            throw NBError.noImageInResponse
        }

        for part in parts {
            if let inlineData = part["inline_data"] as? [String: Any],
               let b64 = inlineData["data"] as? String,
               let imageData = Data(base64Encoded: b64),
               let image = UIImage(data: imageData) {
                return image
            }
        }
        throw NBError.noImageInResponse
    }
}
