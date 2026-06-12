import SwiftUI

struct ResultView: View {
    let result: AngleCorrectionResult
    let onDone: () -> Void

    @State private var showingOriginal  = false
    @State private var showingStreetView = false
    @State private var savedSuccessfully = false
    @State private var saveError: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {

                    // Before / After toggle
                    ZStack(alignment: .topTrailing) {
                        Image(uiImage: showingOriginal
                              ? result.original
                              : result.corrected)
                            .resizable()
                            .scaledToFit()
                            .cornerRadius(12)
                            .shadow(radius: 6)
                            .animation(.easeInOut(duration: 0.25), value: showingOriginal)

                        Text(showingOriginal ? "ORIGINAL" : "CORRECTED")
                            .font(.caption.bold())
                            .foregroundColor(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(showingOriginal ? Color.gray : Color.blue))
                            .padding(12)
                    }
                    .padding(.horizontal)

                    Button {
                        showingOriginal.toggle()
                    } label: {
                        Label(showingOriginal ? "Show Corrected" : "Compare with Original",
                              systemImage: "arrow.left.arrow.right")
                            .font(.subheadline)
                    }

                    // Metadata badge
                    HStack(spacing: 12) {
                        badgeView(icon: "rotate.right",
                                  text: String(format: "%.0f°", result.degreesApplied))
                        badgeView(icon: "arrow.right",
                                  text: result.direction.rawValue)
                        if result.streetViewReference != nil {
                            badgeView(icon: "map", text: "Street View guided")
                        }
                    }
                    .padding(.horizontal)

                    // Street View reference (if available)
                    if let ref = result.streetViewReference {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Street View Reference Used", systemImage: "map")
                                .font(.caption.bold())
                                .foregroundColor(.secondary)
                            Button {
                                showingStreetView.toggle()
                            } label: {
                                ZStack(alignment: .topTrailing) {
                                    Image(uiImage: ref)
                                        .resizable()
                                        .scaledToFit()
                                        .frame(height: showingStreetView ? nil : 120)
                                        .cornerRadius(8)
                                    Image(systemName: showingStreetView ? "chevron.up" : "chevron.down")
                                        .padding(6)
                                        .background(Circle().fill(Color.black.opacity(0.4)))
                                        .foregroundColor(.white)
                                        .padding(8)
                                }
                            }
                        }
                        .padding(.horizontal)
                    }

                    // Save button
                    Button(action: saveToPhotoLibrary) {
                        Label(savedSuccessfully ? "Saved!" : "Save to Camera Roll",
                              systemImage: savedSuccessfully ? "checkmark.circle.fill" : "square.and.arrow.down")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(savedSuccessfully ? Color.green : Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(14)
                    }
                    .padding(.horizontal)
                    .disabled(savedSuccessfully)

                    if let err = saveError {
                        Text(err)
                            .font(.caption)
                            .foregroundColor(.red)
                            .padding(.horizontal)
                    }

                    Button("Done — Back to Camera", action: onDone)
                        .padding(.bottom, 32)
                }
                .padding(.top)
            }
            .navigationTitle("Result")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func saveToPhotoLibrary() {
        UIImageWriteToSavedPhotosAlbum(
            result.corrected, nil, nil, nil
        )
        savedSuccessfully = true
    }

    private func badgeView(icon: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.caption)
            Text(text).font(.caption.bold())
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color.blue.opacity(0.1)))
        .foregroundColor(.blue)
    }
}
