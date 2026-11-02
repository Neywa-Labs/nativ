import AppKit
import NativServerKit
import SwiftUI
import UniformTypeIdentifiers

struct MeshGenerationView: View {
    let model: NativModel
    @ObservedObject var viewModel: MeshGenerationViewModel
    let onSelectWorkspaceMode: (ChatWorkspaceMode) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ChatWorkspacePicker(selection: .threeD, onSelect: onSelectWorkspaceMode)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Image to 3D").font(.title2.weight(.semibold))
                    Text("Turn one object image into a 3D Gaussian splat with Idol.")
                        .foregroundStyle(.secondary)
                }
                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 16) {
                        imageInput
                        Picker("Image type", selection: $viewModel.mode) {
                            Text("Photo").tag(MLXMeshRequest.InputMode.real)
                            Text("Illustration or render").tag(MLXMeshRequest.InputMode.synthetic)
                        }
                        .disabled(viewModel.isGenerating)
                        HStack {
                            Text("Seed")
                            TextField("42", text: $viewModel.seedText)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 120)
                                .disabled(viewModel.isGenerating)
                        }
                        if UInt32(viewModel.seedText) == nil {
                            Text("Enter a whole number from 0 to 4294967295.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Button { viewModel.generate(using: model) } label: {
                            Label("Generate 3D", systemImage: "cube")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!viewModel.canGenerate)
                        if let status = viewModel.statusText {
                            HStack {
                                if viewModel.isGenerating { ProgressView().controlSize(.small) }
                                Text(status).font(.callout).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    resultCard.frame(maxWidth: .infinity, alignment: .leading)
                }
                if let error = viewModel.errorMessage {
                    Label(error, systemImage: "exclamationmark.circle")
                        .foregroundStyle(.red).textSelection(.enabled)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Idol runs locally. The first generation downloads the model and its image encoders.")
                    HStack(spacing: 4) {
                        Text("Encoder access:")
                        Link("DINOv3", destination: URL(string: "https://huggingface.co/facebook/dinov3-vith16plus-pretrain-lvd1689m")!)
                        Text("·")
                        Link("FLUX.2", destination: URL(string: "https://huggingface.co/black-forest-labs/FLUX.2-dev")!)
                        Text("— add your Hugging Face token in Developer.")
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
                if !viewModel.results.isEmpty {
                    Divider()
                    Text("Recent objects").font(.headline)
                    ForEach(viewModel.results) { result in
                        Button { viewModel.selectedID = result.id } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "cube").font(.title3)
                                Text(result.name).lineLimit(1)
                                Spacer()
                                Text(result.createdAt, style: .date).foregroundStyle(.secondary)
                                Text(ByteCountFormatter.string(fromByteCount: result.bytes, countStyle: .file))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(12)
                            .background(
                                viewModel.selectedID == result.id ? Color.primary.opacity(0.06) : .clear,
                                in: RoundedRectangle(cornerRadius: 10)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(32)
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Color.nativMainContentBackground)
    }

    private var imageInput: some View {
        VStack(spacing: 12) {
            if let image = viewModel.sourceImage {
                Image(nsImage: image).resizable().scaledToFit().frame(height: 240)
            } else {
                Image(systemName: "photo.badge.plus").font(.system(size: 38)).foregroundStyle(.secondary)
                    .frame(height: 180)
                Text("Choose one image of an object").foregroundStyle(.secondary)
            }
            Button(viewModel.sourceImage == nil ? "Choose Image…" : "Replace Image…") {
                viewModel.chooseImage()
            }
            .disabled(viewModel.isGenerating)
        }
        .frame(maxWidth: .infinity).padding(20)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
    }

    private var resultCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("3D result", systemImage: "cube.transparent").font(.headline)
            if let result = viewModel.selectedResult {
                if let image = NSImage(contentsOf: viewModel.inputURL(for: result)) {
                    Image(nsImage: image).resizable().scaledToFit().frame(height: 180)
                    Text("Source image").font(.caption).foregroundStyle(.secondary)
                }
                Text(result.name).font(.headline)
                Text("Gaussian splat · PLY · " + ByteCountFormatter.string(fromByteCount: result.bytes, countStyle: .file))
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button("Save PLY…") { viewModel.save(result) }
                    Button("Show in Finder") { viewModel.reveal(result) }
                }
                Text("Open the PLY in a Gaussian splat viewer to explore the object in 3D.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Your generated object will be saved here for export.")
                    .foregroundStyle(.secondary)
                Text("50 steps · 262,144 splats").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 200, alignment: .topLeading)
        .padding(20)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
    }
}
