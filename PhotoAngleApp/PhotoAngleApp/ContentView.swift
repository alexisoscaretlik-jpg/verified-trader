import SwiftUI
import PhotosUI

enum AppScreen {
    case home
    case camera
    case editor(CapturedPhoto)
    case result(AngleCorrectionResult)
}

struct ContentView: View {
    @StateObject private var location = LocationService()
    @State private var screen: AppScreen = .home
    @State private var showingPhotoPicker = false
    @State private var selectedPickerItem: PhotosPickerItem?

    var body: some View {
        switch screen {
        case .home:
            homeView

        case .camera:
            CameraView(location: location) { photo in
                screen = .editor(photo)
            }

        case .editor(let photo):
            AngleEditorView(
                photo: photo,
                onResult: { result in screen = .result(result) },
                onBack:   { screen = .home }
            )

        case .result(let result):
            ResultView(result: result, onDone: { screen = .home })
        }
    }

    // MARK: - Home screen

    private var homeView: some View {
        NavigationStack {
            VStack(spacing: 32) {
                Spacer()

                VStack(spacing: 8) {
                    Image(systemName: "camera.viewfinder")
                        .font(.system(size: 64))
                        .foregroundColor(.blue)
                    Text("PhotoAngle")
                        .font(.largeTitle.bold())
                    Text("Shift your photo's viewpoint 15–50°\nwith Nano Banana AI")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }

                VStack(spacing: 16) {
                    // Take new photo
                    Button {
                        screen = .camera
                    } label: {
                        Label("Take Photo", systemImage: "camera.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(14)
                    }

                    // Pick from library
                    PhotosPicker(selection: $selectedPickerItem,
                                 matching: .images) {
                        Label("Choose from Library", systemImage: "photo.on.rectangle")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.gray.opacity(0.15))
                            .foregroundColor(.primary)
                            .cornerRadius(14)
                    }
                    .onChange(of: selectedPickerItem) { _, item in
                        loadPickedPhoto(item)
                    }
                }
                .padding(.horizontal, 32)

                // Feature description
                VStack(alignment: .leading, spacing: 12) {
                    featureRow(icon: "location.fill",
                               color: .green,
                               text: "Outside? GPS + Street View gives Nano Banana spatial context for photorealistic angle shifts")
                    featureRow(icon: "rotate.right",
                               color: .blue,
                               text: "15–50° horizontal or vertical viewpoint change")
                    featureRow(icon: "wand.and.stars",
                               color: .purple,
                               text: "Powered by Nano Banana 2 (Gemini 2.5 Flash Image)")
                }
                .padding()
                .background(Color.gray.opacity(0.07))
                .cornerRadius(14)
                .padding(.horizontal)

                Spacer()
            }
            .navigationTitle("")
        }
        .onAppear { location.requestPermissionAndStart() }
    }

    // MARK: - Helpers

    private func loadPickedPhoto(_ item: PhotosPickerItem?) {
        guard let item else { return }
        Task {
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else { return }
            let (coord, heading) = location.snapshot()
            let photo = CapturedPhoto(
                image: image,
                coordinate: coord,
                headingDegrees: heading,
                capturedAt: Date()
            )
            await MainActor.run { screen = .editor(photo) }
        }
    }

    private func featureRow(icon: String, color: Color, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(color)
                .frame(width: 24)
            Text(text)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}
