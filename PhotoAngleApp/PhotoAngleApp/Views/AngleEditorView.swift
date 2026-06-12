import SwiftUI

/// Main editing screen — orchestrates the full hybrid pipeline:
///
///  Outdoor (GPS available):
///    Stage 1: ReprojectionEngine (depth + yaw → warped + hole mask)
///    Stage 1b: StreetViewService (GPS + target heading → reference JPEG)
///    Stage 2: NanoBananaService.inpaintHoles (fills mask, guided by Street View)
///    Fallback when no LiDAR: NanoBananaService.fullShift
///
///  Indoor (no GPS):
///    Stage 1: ReprojectionEngine (LiDAR depth → warped + hole mask)
///    Stage 1b: IndoorGroundingService (burst frames fill as many holes as possible)
///    Stage 2: NanoBananaService.inpaintHoles (fills residual mask, guided by burst composite)
///    Fallback when no LiDAR: NanoBananaService.fullShift (pure AI)
struct AngleEditorView: View {
    let photo:    CapturedPhoto
    let onResult: (AngleCorrectionResult) -> Void
    let onBack:   () -> Void

    @State private var degrees:    Double = 25
    @State private var direction:  AngleDirection = .right
    @State private var step        = ""
    @State private var isWorking   = false
    @State private var errorMsg:   String?
    @State private var showDiag    = false       // show hole-mask debug toggle

    private let nanoBanana  = NanoBananaService()
    private let streetView  = StreetViewService()
    private let indoorFill  = IndoorGroundingService()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // Preview
                    Image(uiImage: photo.image)
                        .resizable().scaledToFit()
                        .cornerRadius(12).shadow(radius: 5)
                        .padding(.horizontal)

                    // Mode badge
                    modeBadge

                    // Angle slider
                    VStack(alignment: .leading, spacing: 8) {
                        Label(String(format: "Angle shift: %.0f°", degrees),
                              systemImage: "rotate.right").font(.headline)
                        Slider(value: $degrees, in: 15...50, step: 1).tint(.blue)
                        HStack {
                            Text("15°").font(.caption).foregroundColor(.secondary)
                            Spacer()
                            Text("50°").font(.caption).foregroundColor(.secondary)
                        }
                    }.padding(.horizontal)

                    // Direction
                    directionPicker

                    // Error
                    if let e = errorMsg {
                        Text(e).font(.caption).foregroundColor(.red)
                            .multilineTextAlignment(.center).padding(.horizontal)
                    }

                    // CTA
                    Button(action: runPipeline) {
                        Group {
                            if isWorking {
                                HStack {
                                    ProgressView().tint(.white)
                                    Text(step.isEmpty ? "Working…" : step)
                                        .foregroundColor(.white)
                                }
                            } else {
                                Label("Correct with Hybrid AI",
                                      systemImage: "wand.and.stars")
                                    .font(.headline).foregroundColor(.white)
                            }
                        }
                        .frame(maxWidth: .infinity).padding()
                        .background(isWorking ? Color.blue.opacity(0.6) : Color.blue)
                        .cornerRadius(14)
                    }
                    .disabled(isWorking)
                    .padding(.horizontal)

                    // Pipeline explanation
                    pipelineCard
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

    // MARK: - Sub-views

    private var modeBadge: some View {
        HStack(spacing: 16) {
            modeChip(
                icon: photo.isIndoor ? "house.fill" : "location.fill",
                text: photo.isIndoor ? "Indoor" : "Outdoor",
                color: photo.isIndoor ? .cyan : .green
            )
            modeChip(
                icon: photo.hasLiDAR ? "dot.radiowaves.right" : "camera",
                text: photo.hasLiDAR ? "LiDAR depth" : "No depth (AI only)",
                color: photo.hasLiDAR ? .blue : .orange
            )
            modeChip(
                icon: "square.stack",
                text: "\(photo.burstFrames.count) burst",
                color: .purple
            )
        }
        .padding(.horizontal)
    }

    private func modeChip(icon: String, text: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
            Text(text)
        }
        .font(.caption.bold())
        .foregroundColor(color)
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(Capsule().fill(color.opacity(0.12)))
    }

    private var directionPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Direction", systemImage: "arrow.up.left.and.arrow.down.right")
                .font(.headline).padding(.horizontal)
            HStack(spacing: 10) {
                ForEach(AngleDirection.allCases, id: \.self) { dir in
                    Button {
                        direction = dir
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: dirIcon(dir)).font(.title2)
                            Text(dir.rawValue).font(.caption)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 10)
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
            .padding(.horizontal)
        }
    }

    private var pipelineCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Pipeline").font(.caption.bold()).foregroundColor(.secondary)
            if photo.hasLiDAR {
                Text(photo.isIndoor
                     ? "①  LiDAR depth → geometric \(Int(degrees))° view change\n②  \(photo.burstFrames.count) burst frames fill disocclusion holes\n③  Nano Banana 2 fills remaining gaps, guided by burst composite"
                     : "①  Depth Pro → geometric \(Int(degrees))° view change\n②  Street View at GPS + \(Int(degrees))° heading as reference\n③  Nano Banana 2 fills holes, guided by Street View")
                    .font(.caption).foregroundColor(.secondary)
            } else {
                Text("No LiDAR — Nano Banana 2 does the full shift (pure AI).\nFor best results use iPhone Pro with LiDAR.")
                    .font(.caption).foregroundColor(.orange)
            }
        }
        .padding()
        .background(Color.gray.opacity(0.07))
        .cornerRadius(10)
        .padding(.horizontal)
        .padding(.bottom, 32)
    }

    // MARK: - Pipeline

    private func runPipeline() {
        errorMsg  = nil
        isWorking = true

        Task {
            do {
                let result: AngleCorrectionResult

                if photo.hasLiDAR, let depth = photo.depth {
                    result = try await hybridPipeline(depth: depth)
                } else {
                    result = try await fallbackPipeline()
                }

                await MainActor.run {
                    isWorking = false
                    onResult(result)
                }
            } catch {
                await MainActor.run {
                    isWorking = false
                    errorMsg  = error.localizedDescription
                }
            }
        }
    }

    // Full hybrid: geometry first, AI only fills the gaps
    private func hybridPipeline(depth: [Float]) async throws -> AngleCorrectionResult {
        let yaw   = Float(degrees) * direction.yawOffset
        let pitch = Float(degrees) * direction.pitchOffset
        let orbit = photo.medianDepth

        // ── Stage 1: geometric reprojection ──────────────────────────────
        await setStep("Stage 1: geometric view change…")
        let reproj = await Task.detached(priority: .userInitiated) {
            ReprojectionEngine.reproject(
                image:         self.photo.image,
                depth:         depth,
                imageSize:     self.photo.imageSize,
                yawDeg:        yaw,
                pitchDeg:      pitch,
                fovDeg:        70.0,
                orbitDistance: orbit
            )
        }.value

        // ── Stage 1b: get a grounding reference ──────────────────────────
        var reference: UIImage? = nil
        var streetViewImg: UIImage? = nil

        if photo.isIndoor {
            await setStep("Filling holes from burst frames…")
            let fillResult = await Task.detached(priority: .userInitiated) {
                self.indoorFill.fill(
                    warped:        reproj.warped,
                    holeMask:      reproj.holeMask,
                    burstFrames:   self.photo.burstFrames,
                    mainTransform: simd_float4x4(1),      // identity; relative poses are in ARBurstFrame.transform
                    yawDeg:        yaw,
                    orbitDist:     orbit
                )
            }.value

            reference = fillResult.filled  // burst-filled image as composite reference
            let pctFilled = fillResult.filledPercent
            await setStep(String(format: "Burst filled %.0f%% of holes…", pctFilled))

        } else if let coord = photo.coordinate {
            await setStep("Fetching Street View reference…")
            let targetHeading = ((photo.headingDegrees ?? 0) + Double(yaw)).truncatingRemainder(dividingBy: 360)
            streetViewImg = try? await streetView.fetchReferenceImage(
                at: coord,
                heading: targetHeading,
                pitch: Double(pitch)
            )
            reference = streetViewImg
        }

        // ── Stage 2: Nano Banana fills the remaining holes ────────────────
        await setStep("Nano Banana: filling remaining holes…")
        let finalImage = try await nanoBanana.inpaintHoles(
            warped:    reproj.warped,
            holeMask:  reproj.holeMask,
            reference: reference,
            degrees:   degrees,
            isIndoor:  photo.isIndoor
        )

        return AngleCorrectionResult(
            original:            photo.image,
            corrected:           finalImage,
            streetViewReference: streetViewImg,
            warpedWithHoles:     reproj.warped,
            holeMask:            reproj.holeMask,
            holePercent:         reproj.holePercent,
            degreesApplied:      degrees,
            direction:           direction,
            wasIndoor:           photo.isIndoor
        )
    }

    // No LiDAR: pure Nano Banana (old approach, still useful for non-Pro phones)
    private func fallbackPipeline() async throws -> AngleCorrectionResult {
        await setStep("No depth data — Nano Banana full shift…")
        var streetViewImg: UIImage? = nil

        if !photo.isIndoor, let coord = photo.coordinate {
            let th = ((photo.headingDegrees ?? 0) + Double(direction.yawOffset) * degrees)
                .truncatingRemainder(dividingBy: 360)
            streetViewImg = try? await streetView.fetchReferenceImage(
                at: coord, heading: th)
        }

        let result = try await nanoBanana.fullShift(
            photo:      photo.image,
            degrees:    degrees,
            direction:  direction,
            streetView: streetViewImg
        )

        return AngleCorrectionResult(
            original:            photo.image,
            corrected:           result,
            streetViewReference: streetViewImg,
            warpedWithHoles:     nil,
            holeMask:            nil,
            holePercent:         100,
            degreesApplied:      degrees,
            direction:           direction,
            wasIndoor:           photo.isIndoor
        )
    }

    private func setStep(_ s: String) async {
        await MainActor.run { step = s }
    }

    private func dirIcon(_ d: AngleDirection) -> String {
        switch d {
        case .left:  return "arrow.left"
        case .right: return "arrow.right"
        case .up:    return "arrow.up"
        case .down:  return "arrow.down"
        }
    }
}
