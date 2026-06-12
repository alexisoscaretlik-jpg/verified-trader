# PhotoAngle — AI Photo Angle Correction for iPhone

Shift any photo's viewpoint 15–50 degrees using **Nano Banana 2** (Google's Gemini 2.5 Flash Image model). When you shoot outdoors, the app fetches a **Google Street View panorama** at your exact GPS location to give the AI spatial context, producing far more accurate results than angle-shifting without reference data.

---

## How It Works

```
[iPhone Camera] ──► [GPS + Compass heading captured]
       │
       ▼
[AngleEditorView]
  ├─ Slider: 15–50 degrees
  └─ Direction: Left / Right / Up / Down
       │
       ├─ (if GPS available)
       │    └─ Street View Static API
       │         location = user's GPS coordinates
       │         heading  = user's compass + degree offset
       │         → returns JPEG of scene at target angle
       │
       └─ Nano Banana 2 (Gemini 2.5 Flash Image API)
            input 1: user's photo
            input 2: Street View reference (if available)
            prompt:  "Re-render from N° [direction] viewpoint…"
            → returns AI-synthesized angle-shifted image
```

**Why Street View matters:** Nano Banana 2 is a diffusion model — without reference data it must *hallucinate* geometry that was occluded in the original photo. The Street View image at the target heading shows the AI what the scene actually looks like from that angle, dramatically reducing artifacts for 15–50° shifts.

---

## Setup

### 1. Get API Keys

| Key | Where to get it |
|-----|----------------|
| **Gemini API key** (Nano Banana 2) | https://aistudio.google.com/apikey — free tier includes image generation |
| **Google Maps API key** | https://console.cloud.google.com → Enable **Street View Static API** |

### 2. Add Your Keys

Open `PhotoAngleApp/Config.swift` and fill in:

```swift
static let geminiAPIKey = "AIza..."       // your Gemini key
static let mapsAPIKey   = "AIza..."       // your Maps key
```

### 3. Open in Xcode

1. Open **Xcode 16+** (requires iOS 17 SDK)
2. **File → New → Project** — choose *App* template
3. Product name: `PhotoAngleApp`, Bundle ID: `com.yourname.PhotoAngleApp`
4. **Delete** the auto-generated `ContentView.swift` and `AppName.swift`
5. Drag the entire `PhotoAngleApp/` source folder into the Xcode project navigator
6. Replace the generated `Info.plist` with the one in this folder
7. In project settings → **Signing & Capabilities**, add your Apple Developer team
8. Connect your iPhone, select it as run target, press **▶ Run**

> **No third-party dependencies** — the app uses only URLSession, AVFoundation, CoreLocation, SwiftUI, and PhotosUI. No CocoaPods, SPM packages, or Firebase needed.

### 4. Permissions on First Launch

The app will request:
- **Camera** — for taking photos
- **Location (When In Use)** — for GPS coordinates + compass heading
- **Photo Library** — for saving results and picking existing photos

---

## File Structure

```
PhotoAngleApp/
├── PhotoAngleAppApp.swift          @main entry point
├── ContentView.swift               Navigation state machine (Home/Camera/Editor/Result)
├── Config.swift                    API keys — fill in before running
├── Info.plist                      App permissions
├── Camera/
│   ├── CameraManager.swift         AVFoundation session + photo capture
│   └── CameraView.swift            SwiftUI camera preview + shutter UI
├── Services/
│   ├── LocationService.swift       CLLocationManager wrapper (GPS + compass)
│   ├── StreetViewService.swift     Google Street View Static API client
│   └── NanoBananaService.swift     Gemini 2.5 Flash Image (Nano Banana 2) client
├── Views/
│   ├── AngleEditorView.swift       Angle slider, direction picker, pipeline trigger
│   └── ResultView.swift            Before/After comparison + save to Camera Roll
└── Models/
    └── CapturedPhoto.swift         Data models (CapturedPhoto, AngleCorrectionResult, etc.)
```

---

## Technical Details

### Nano Banana 2 API call

```
POST https://generativelanguage.googleapis.com/v1beta/models/
     gemini-2.5-flash-preview-04-17:generateContent?key={API_KEY}

{
  "contents": [{
    "role": "user",
    "parts": [
      {"text": "Re-render from 30° right viewpoint… [full prompt]"},
      {"inline_data": {"mime_type": "image/jpeg", "data": "<user photo base64>"}},
      {"inline_data": {"mime_type": "image/jpeg", "data": "<street view base64>"}}  // if GPS
    ]
  }],
  "generationConfig": {
    "responseModalities": ["Text", "Image"],
    "temperature": 1.0
  }
}
```

### Street View request

```
GET https://maps.googleapis.com/maps/api/streetview
    ?size=640x480
    &location={lat},{lng}       ← from iPhone GPS at capture time
    &heading={current + offset} ← compass heading + degree shift
    &pitch={0 or ±offset}       ← for Up/Down corrections
    &fov=90
    &key={MAPS_API_KEY}
```

### What Nano Banana 2 *can* and *cannot* do

| ✅ Works well | ⚠️ Limitations |
|---|---|
| 15–35° horizontal shifts | >45° shifts reveal large occluded areas; quality degrades |
| Outdoor scenes with Street View coverage | Indoor photos: no Street View → relies on model priors |
| Urban environments | Rural / unique scenes with no nearby Street View data |
| Consistent lighting/style preservation | Exact geometric reconstruction — this is *plausible synthesis*, not photogrammetry |

---

## Cost Estimates (as of June 2026)

| API | Rate |
|-----|------|
| Gemini 2.5 Flash Image (Nano Banana 2) | ~$0.04 per image generation |
| Street View Static API | $7 per 1,000 images (first 25,000/month free) |

---

## Known Limitations & Honest Caveats

1. **Not geometric reconstruction** — Nano Banana 2 synthesizes a *plausible* new viewpoint using diffusion; it does not do true 3D reconstruction (that would require NeRF or 3D Gaussian Splatting).
2. **Apple SHARP** (open-source, Dec 2025) could provide on-device depth estimation before the API call, improving results — a community CoreML conversion exists at `pearsonkyle/Sharp-coreml` on Hugging Face, but it is NOT officially part of iOS and requires manual integration.
3. **Street View coverage gaps** — the API returns a placeholder image when no coverage exists within 50m; the app detects this and falls back to GPS-free mode automatically.
4. **Processing time** — image generation typically takes 20–60 seconds; a loading state with step labels keeps the user informed.
