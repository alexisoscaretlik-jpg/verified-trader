import Foundation

enum Config {
    // ── API keys ────────────────────────────────────────────────────────
    // Gemini (Nano Banana 2): https://aistudio.google.com/apikey
    static let geminiAPIKey    = "YOUR_GEMINI_API_KEY"

    // Google Maps (Street View Static API): https://console.cloud.google.com
    // Enable: Street View Static API
    static let mapsAPIKey      = "YOUR_GOOGLE_MAPS_API_KEY"

    // ── Model ────────────────────────────────────────────────────────────
    // Nano Banana 2 = Gemini 2.5 Flash Image (native image generation)
    static let nanoBananaModel = "gemini-2.5-flash-preview-04-17"

    // ── Endpoints ────────────────────────────────────────────────────────
    static let geminiBaseURL   = "https://generativelanguage.googleapis.com/v1beta/models"
    static let streetViewURL   = "https://maps.googleapis.com/maps/api/streetview"

    // ── Reprojection ─────────────────────────────────────────────────────
    // iPhone wide camera horizontal field of view (degrees)
    static let cameraFOV: Float = 70.0
}
