/*
See LICENSE folder for this sample’s licensing information.

Abstract:
A view that displays scene depth information.
*/

import Foundation
import SwiftUI
import MetalKit
import Metal

//- Tag: CoordinatorDepth
final class CoordinatorRGB: MTKCoordinator {
    
    init(rgbContent: MetalTextureContent) {
        super.init(content: rgbContent)
    }
    override func prepareFunctions() {
        guard let metalDevice = mtkView.device else { fatalError("Expected a Metal device.") }
        do {
            let library = EnvironmentVariables.shared.metalLibrary
            let pipelineDescriptor = MTLRenderPipelineDescriptor()
            pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            pipelineDescriptor.depthAttachmentPixelFormat = .depth32Float
            pipelineDescriptor.vertexFunction = library.makeFunction(name: "planeVertexShader")
            pipelineDescriptor.fragmentFunction = library.makeFunction(name: "planeFragmentShader")
            pipelineDescriptor.vertexDescriptor = createPlaneMetalVertexDescriptor()
            pipelineState = try metalDevice.makeRenderPipelineState(descriptor: pipelineDescriptor)
        } catch {
            print("Unexpected error: \(error).")
        }
    }

}

struct MetalTextureViewRGB: UIViewRepresentable {
    var content: MetalTextureContent
    
    func makeCoordinator() -> CoordinatorRGB {
        CoordinatorRGB(rgbContent: content)
    }
    
    func makeUIView(context: UIViewRepresentableContext<MetalTextureViewRGB>) -> MTKView {
        let mtkView = MTKView()
        mtkView.delegate = context.coordinator
        mtkView.backgroundColor = context.environment.colorScheme == .dark ? .black : .white
        context.coordinator.setupView(mtkView: mtkView)
        return mtkView
    }
    
    // `UIViewRepresentable` requires this implementation; however, the sample
    // app doesn't use it. Instead, `MTKView.delegate` handles display updates.
    func updateUIView(_ uiView: MTKView, context: UIViewRepresentableContext<MetalTextureViewRGB>) {
        
    }
}

