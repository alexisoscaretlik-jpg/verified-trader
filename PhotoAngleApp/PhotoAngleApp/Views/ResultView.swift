import SwiftUI

struct ResultView: View {
    let result: AngleCorrectionResult
    let onDone: () -> Void

    @State private var showOriginal   = false
    @State private var showDiagnostics = false
    @State private var saved = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {

                    // ── Main image toggle ─────────────────────────────────
                    ZStack(alignment: .topTrailing) {
                        Image(uiImage: showOriginal ? result.original : result.corrected)
                            .resizable().scaledToFit()
                            .cornerRadius(12).shadow(radius: 6)
                            .animation(.easeInOut(duration: 0.2), value: showOriginal)

                        Text(showOriginal ? "ORIGINAL" : "CORRECTED")
                            .font(.caption.bold()).foregroundColor(.white)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Capsule().fill(showOriginal ? Color.gray : Color.blue))
                            .padding(10)
                    }
                    .padding(.horizontal)

                    Button {
                        showOriginal.toggle()
                    } label: {
                        Label(showOriginal ? "Show Corrected" : "Compare Original",
                              systemImage: "arrow.left.arrow.right").font(.subheadline)
                    }

                    // ── Metadata badges ───────────────────────────────────
                    HStack(spacing: 10) {
                        badge("rotate.right",
                              String(format: "%.0f°", result.degreesApplied))
                        badge("arrow.right", result.direction.rawValue)
                        badge(result.wasIndoor ? "house.fill" : "location.fill",
                              result.wasIndoor ? "Indoor" : "Outdoor")
                        if !result.wasIndoor || result.holePercent < 99 {
                            badge("waveform",
                                  String(format: "%.0f%% AI", result.holePercent))
                        }
                    }
                    .padding(.horizontal)

                    // ── Diagnostics (stage-1 output + mask) ──────────────
                    if result.warpedWithHoles != nil || result.streetViewReference != nil {
                        DisclosureGroup("Diagnostics", isExpanded: $showDiagnostics) {
                            VStack(alignment: .leading, spacing: 12) {
                                if let warped = result.warpedWithHoles {
                                    diagRow(warped, label: "Stage 1: geometry only",
                                            note: String(format: "%.0f%% holes", result.holePercent))
                                }
                                if let mask = result.holeMask {
                                    diagRow(mask, label: "Hole mask (white = AI fill region)")
                                }
                                if let sv = result.streetViewReference {
                                    diagRow(sv, label: result.wasIndoor
                                            ? "Indoor grounding (burst composite)"
                                            : "Street View reference (outdoor grounding)")
                                }
                            }
                        }
                        .padding(.horizontal)
                    }

                    // ── Save ─────────────────────────────────────────────
                    Button(action: save) {
                        Label(saved ? "Saved!" : "Save to Camera Roll",
                              systemImage: saved ? "checkmark.circle.fill" : "square.and.arrow.down")
                            .font(.headline).frame(maxWidth: .infinity).padding()
                            .background(saved ? Color.green : Color.blue)
                            .foregroundColor(.white).cornerRadius(14)
                    }
                    .disabled(saved)
                    .padding(.horizontal)

                    Button("Done", action: onDone).padding(.bottom, 32)
                }
                .padding(.top)
            }
            .navigationTitle("Result")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func badge(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.caption)
            Text(text).font(.caption.bold())
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(Capsule().fill(Color.blue.opacity(0.1)))
        .foregroundColor(.blue)
    }

    private func diagRow(_ img: UIImage, label: String, note: String = "") -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.caption.bold()).foregroundColor(.secondary)
                if !note.isEmpty {
                    Text(note).font(.caption).foregroundColor(.orange)
                }
            }
            Image(uiImage: img).resizable().scaledToFit()
                .cornerRadius(6)
        }
    }

    private func save() {
        UIImageWriteToSavedPhotosAlbum(result.corrected, nil, nil, nil)
        saved = true
    }
}
