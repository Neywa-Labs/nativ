import MetalKit
import SwiftUI

struct GaussianSplatPreview: View {
    let url: URL
    let cameraURL: URL?
    @State private var renderer: GaussianSplatRenderer?
    @State private var errorMessage: String?
    @State private var initialCamera = GaussianSplatCamera()

    var body: some View {
        ZStack {
            Color(red: 0.035, green: 0.043, blue: 0.051)
            if let renderer {
                GaussianSplatMetalView(renderer: renderer)
                VStack {
                    Spacer()
                    VStack(spacing: 8) {
                        Text("Drag to rotate · Scroll to zoom").font(.caption)
                        HStack(spacing: 18) {
                            Button { renderer.camera.orbit(dx: 30, dy: 0) } label: {
                                Image(systemName: "rotate.left")
                            }.help("Rotate left")
                            Button { renderer.camera.orbit(dx: -30, dy: 0) } label: {
                                Image(systemName: "rotate.right")
                            }.help("Rotate right")
                            Button { renderer.camera.magnify(15) } label: {
                                Image(systemName: "plus.magnifyingglass")
                            }.help("Zoom in")
                            Button { renderer.camera.magnify(-15) } label: {
                                Image(systemName: "minus.magnifyingglass")
                            }.help("Zoom out")
                            Button { renderer.camera = initialCamera } label: {
                                Image(systemName: "arrow.counterclockwise")
                            }.help("Reset view")
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .buttonStyle(.plain)
                    .padding(10)
                    .background(.black.opacity(0.65))
                }
                .foregroundStyle(.white)
            } else if let errorMessage {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                    Text(errorMessage).font(.callout).multilineTextAlignment(.center)
                }.foregroundStyle(.white).padding()
            } else {
                ProgressView("Loading 3D preview…").tint(.white).foregroundStyle(.white)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .task(id: url) {
            renderer = nil
            errorMessage = nil
            let load = Task.detached(priority: .userInitiated) { try GaussianSplatScene(url: url) }
            do {
                let scene = try await withTaskCancellationHandler { try await load.value } onCancel: { load.cancel() }
                try Task.checkCancellation()
                initialCamera = GaussianSplatCamera(url: cameraURL)
                renderer = try GaussianSplatRenderer(scene: scene, camera: initialCamera)
            } catch is CancellationError {
                // A different result was selected while decoding.
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct GaussianSplatMetalView: NSViewRepresentable {
    let renderer: GaussianSplatRenderer

    func makeNSView(context: Context) -> SplatView {
        let view = SplatView(frame: .zero, device: renderer.device)
        view.colorPixelFormat = .bgra8Unorm
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.renderer = renderer
        view.delegate = renderer
        renderer.view = view
        view.setAccessibilityLabel("3D Gaussian splat preview. Drag to rotate and scroll to zoom.")
        return view
    }

    func updateNSView(_ view: SplatView, context: Context) {
        view.renderer = renderer
        view.delegate = renderer
        renderer.view = view
        renderer.requestFrame()
    }

    final class SplatView: MTKView {
        var renderer: GaussianSplatRenderer?
        override var acceptsFirstResponder: Bool { true }
        override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }
        override func mouseDragged(with event: NSEvent) {
            renderer?.camera.orbit(dx: Float(event.deltaX), dy: Float(event.deltaY))
        }
        override func scrollWheel(with event: NSEvent) {
            renderer?.camera.magnify(Float(event.scrollingDeltaY))
        }
        override func magnify(with event: NSEvent) {
            renderer?.camera.magnify(Float(event.magnification) * 100)
        }
    }
}
