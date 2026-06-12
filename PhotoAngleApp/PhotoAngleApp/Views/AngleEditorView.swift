import SwiftUI

/// The main editing screen: shows the captured photo, lets the user pick
/// angle degrees (15–50) and direction, then kicks off Nano Banana 2.
struct AngleEditorView: View {
    let photo: CapturedPhoto
    let onResult: (AngleCorrectionResult) -> Void
    let onBack: () -> Void

    @State private var degrees: Double = 25
    @State private var direction: AngleDirection = .right
    @State private var isProcessing = false
    @State private var processingStep = ""
    @State private var errorMessage: String?

    private let nanoBanana  = NanoBananaService()
    private let streetView  = StreetViewService()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // Preview
                    Image(uiImage: photo.image)
                        .resizable()
                        .scaledToFit()
                        .cornerRadius(12)
                        .shadow(radius: 6)
                        .padding(.horizontal)

                    // GPS badge
                    if photo.hasGPS {
                        HStack {
                            Image(systemName: "location.fill")
                            Text("Street View reference will be used")
                        }
                        .font(.caption.bold())
                        .foregroundColor(.green)
                        .padding(8)
                        .background(Capsule().fill(Color.green.opacity(0.12)))
                    } else {
                        HStack {
                            Image(systemName: "location.slash")
                            Text("No GPS — angle change without Street View")
                        }
                        .font(.caption)
                        .foregroundColor(.orange)
                        .padding(8)
                        .background(Capsule().fill(Color.orange.opacity(0.12)))
                    }

                    // Angle slider
                    VStack(alignment: .leading, spacing: 8) {
                        Label(String(format: "Angle shift: %.0f°", degrees),
                              systemImage: "rotate.right")
                            .font(.headline)
                        Slider(value: $degrees, in: 15...50, step: 1)
                            .tint(.blue)
                        HStack {
                            Text("15°").font(.caption).foregroundColor(.secondary)
                            Spacer()
                            Text("50°").font(.caption).foregroundColor(.secondary)
                        }
                    }
                    .padding(.horizontal)

                    // Direction picker
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Direction", systemImage: "arrow.up.left.and.arrow.down.right")
                            .font(.headline)
                        HStack(spacing: 12) {
                            ForEach(AngleDirection.allCases, id: \.self) { dir in
                                Button {
                                    direction = dir
                                } label: {
                                    VStack(spacing: 4) {
                                        Image(systemName: directionIcon(dir))
                                            .font(.title2)
                                        Text(dir.rawValue)
                                            .font(.caption)
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                                    .background(
                                        RoundedRectangle(cornerRadius: 10)
                                            .fill(direction == dir
                                                  ? Color.blue.opacity(0.2)
                                                  : Color.gray.opacity(0.1))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10)
                                            .stroke(direction == dir ? Color.blue : Color.clear,
                                                    lineWidth: 2)
                                    )
                                }
                                .foregroundColor(direction == dir ? .blue : .primary)
                            }
                        }
                    }
                    .padding(.horizontal)

                    // Error
                    if let err = errorMessage {
                        Text(err)
                            .font(.caption)
                            .foregroundColor(.red)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }

                    // CTA
                    Button(action: startCorrection) {
                        if isProcessing {
                            HStack {
                                ProgressView()
                                    .tint(.white)
                                Text(processingStep)
                                    .foregroundColor(.white)
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.blue.opacity(0.7))
                            .cornerRadius(14)
                        } else {
                            Label("Correct Angle with Nano Banana", systemImage: "wand.and.stars")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(Color.blue)
                                .foregroundColor(.white)
                                .cornerRadius(14)
                        }
                    }
                    .disabled(isProcessing)
                    .padding(.horizontal)

                    // What happens explanation
                    VStack(alignment: .leading, spacing: 6) {
                        Text("How it works")
                            .font(.caption.bold())
                            .foregroundColor(.secondary)
                        Text(photo.hasGPS
                             ? "1. Fetches a Street View panorama at your GPS location looking \(Int(degrees))° \(direction.rawValue.lowercased())\n2. Sends your photo + Street View reference to Nano Banana 2 (Gemini 2.5 Flash Image)\n3. AI synthesizes the scene from the shifted viewpoint"
                             : "1. Sends your photo to Nano Banana 2 (Gemini 2.5 Flash Image)\n2. AI synthesizes the scene from a viewpoint \(Int(degrees))° \(direction.rawValue.lowercased())\n3. For better results, take photos outdoors with GPS enabled")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding()
                    .background(Color.gray.opacity(0.08))
                    .cornerRadius(10)
                    .padding(.horizontal)

                    Spacer(minLength: 32)
                }
                .padding(.top)
            }
            .navigationTitle("Angle Editor")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Back", action: onBack)
                }
            }
        }
    }

    // MARK: - Correction pipeline

    private func startCorrection() {
        errorMessage = nil
        isProcessing = true

        Task {
            do {
                var streetViewRef: UIImage? = nil

                if photo.hasGPS, let coord = photo.coordinate {
                    processingStep = "Fetching Street View…"
                    let currentHeading = photo.headingDegrees ?? 0
                    let targetHeading  = currentHeading
                        + direction.streetViewHeadingOffset * degrees
                    let targetPitch    = direction.streetViewPitchOffset * degrees

                    // Best-effort: if Street View has no coverage, continue without it
                    streetViewRef = try? await streetView.fetchReferenceImage(
                        at: coord,
                        heading: targetHeading,
                        pitch: targetPitch
                    )
                }

                processingStep = "Generating with Nano Banana…"
                let result = try await nanoBanana.correctAngle(
                    photo: photo.image,
                    degrees: degrees,
                    direction: direction,
                    streetViewReference: streetViewRef
                )

                let correctionResult = AngleCorrectionResult(
                    original: photo.image,
                    corrected: result,
                    streetViewReference: streetViewRef,
                    degreesApplied: degrees,
                    direction: direction
                )

                await MainActor.run {
                    isProcessing = false
                    onResult(correctionResult)
                }

            } catch {
                await MainActor.run {
                    isProcessing = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func directionIcon(_ dir: AngleDirection) -> String {
        switch dir {
        case .left:  return "arrow.left"
        case .right: return "arrow.right"
        case .up:    return "arrow.up"
        case .down:  return "arrow.down"
        }
    }
}
