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
    @State private var pickerItem: PhotosPickerItem?

    var body: some View {
        switch screen {
        case .home:
            homeView

        case .camera:
            ARCameraView(location: location) { photo in
                screen = .editor(photo)
            }

        case .editor(let photo):
            AngleEditorView(
                photo:    photo,
                onResult: { screen = .result($0) },
                onBack:   { screen = .home }
            )

        case .result(let result):
            ResultView(result: result, onDone: { screen = .home })
        }
    }

    // MARK: - Home

    private var homeView: some View {
        NavigationStack {
            VStack(spacing: 28) {
                Spacer()

                VStack(spacing: 8) {
                    Image(systemName: "camera.viewfinder")
                        .font(.system(size: 60)).foregroundColor(.blue)
                    Text("PhotoAngle")
                        .font(.largeTitle.bold())
                    Text("Hybrid AI photo angle correction\n15–50° — works indoors & outdoors")
                        .font(.subheadline).foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }

                VStack(spacing: 14) {
                    Button { screen = .camera } label: {
                        Label("Take Photo", systemImage: "camera.fill")
                            .font(.headline).frame(maxWidth: .infinity).padding()
                            .background(Color.blue).foregroundColor(.white)
                            .cornerRadius(14)
                    }

                    PhotosPicker(selection: $pickerItem, matching: .images) {
                        Label("Choose from Library", systemImage: "photo.on.rectangle")
                            .font(.headline).frame(maxWidth: .infinity).padding()
                            .background(Color.gray.opacity(0.12)).foregroundColor(.primary)
                            .cornerRadius(14)
                    }
                    .onChange(of: pickerItem) { _, item in loadPicked(item) }
                }
                .padding(.horizontal, 28)

                // How it works
                VStack(alignment: .leading, spacing: 10) {
                    featureRow(icon: "dot.radiowaves.right", color: .blue,
                               text: "LiDAR depth → real geometric rotation (Stage 1)")
                    featureRow(icon: "house.fill", color: .cyan,
                               text: "Indoor: burst frames fill holes with real captured pixels")
                    featureRow(icon: "location.fill", color: .green,
                               text: "Outdoor: Street View reference grounds the AI fill")
                    featureRow(icon: "wand.and.stars", color: .purple,
                               text: "Nano Banana 2 fills only remaining gaps — not the whole image")
                }
                .padding()
                .background(Color.gray.opacity(0.07))
                .cornerRadius(14)
                .padding(.horizontal)

                Spacer()
            }
        }
        .onAppear { location.requestPermissionAndStart() }
    }

    private func loadPicked(_ item: PhotosPickerItem?) {
        guard let item else { return }
        Task {
            guard let data  = try? await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else { return }
            let (coord, heading) = location.snapshot()
            let photo = CapturedPhoto(
                image:          image,
                imageSize:      image.size,
                depth:          nil,              // library photos have no LiDAR
                burstFrames:    [],
                coordinate:     coord,
                headingDegrees: heading,
                capturedAt:     Date()
            )
            await MainActor.run { screen = .editor(photo) }
        }
    }

    private func featureRow(icon: String, color: Color, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundColor(color).frame(width: 22)
            Text(text).font(.caption).foregroundColor(.secondary)
        }
    }
}
