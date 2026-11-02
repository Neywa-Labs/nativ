import SwiftUI

enum ImagesWorkspaceMode: String, CaseIterable, Identifiable {
    case images = "Images"
    case object = "Image to 3D"
    var id: Self { self }
}

struct ImagesWorkspaceView: View {
    let model: NativModel
    let imageGeneration: ImageGenerationViewModel
    let meshGeneration: MeshGenerationViewModel
    @Binding var mode: ImagesWorkspaceMode
    let onSelectWorkspaceMode: (ChatWorkspaceMode) -> Void
    let onExploreImageModels: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                ChatWorkspacePicker(selection: .images, onSelect: onSelectWorkspaceMode)
                Spacer()
                Picker("Create", selection: $mode) {
                    ForEach(ImagesWorkspaceMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 14)
            Divider()
            switch mode {
            case .images:
                ImageGenerationView(
                    model: model, viewModel: imageGeneration,
                    onExploreImageModels: onExploreImageModels
                )
            case .object:
                MeshGenerationView(model: model, viewModel: meshGeneration)
            }
        }
        .background(Color.nativMainContentBackground)
    }
}
