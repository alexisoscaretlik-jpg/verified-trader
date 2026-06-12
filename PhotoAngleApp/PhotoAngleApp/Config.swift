import Foundation

/// Fill in your API keys before running.
/// Gemini API key: https://aistudio.google.com/apikey
/// Google Maps API key (must have Street View Static API enabled):
/// https://console.cloud.google.com/apis/library/streetviewpublish.googleapis.com
enum Config {
    static let geminiAPIKey   = "YOUR_GEMINI_API_KEY"
    static let mapsAPIKey     = "YOUR_GOOGLE_MAPS_API_KEY"

    // Nano Banana 2 = Gemini 2.5 Flash Image (gemini-2.5-flash-exp image-generation variant)
    static let nanoBananaModel = "gemini-2.5-flash-preview-04-17"

    static let geminiBaseURL  = "https://generativelanguage.googleapis.com/v1beta/models"
    static let streetViewURL  = "https://maps.googleapis.com/maps/api/streetview"
}
