import MetalKit
import SwiftUI

struct ViewfinderView: UIViewRepresentable {
    let renderer: PreviewRenderer?

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView()
        view.backgroundColor = .black
        renderer?.configure(view: view)
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {}
}
