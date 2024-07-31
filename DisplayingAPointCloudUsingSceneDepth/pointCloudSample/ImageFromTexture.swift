import Metal
import MetalKit
import CoreImage
import UIKit

class ImageFromTexture {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    var ciContext: CIContext
    var pipelineStateRGBA32Float: MTLRenderPipelineState?
    var pipelineStateR32Float: MTLRenderPipelineState?
    var pipelineStateR8Unorm: MTLRenderPipelineState?
    var vertexBuffer: MTLBuffer?

    init(device: MTLDevice) {
        self.device = device
        self.commandQueue = device.makeCommandQueue()!
        self.ciContext = CIContext(mtlDevice: device)
        self.setupPipeline()
        self.setupVertexBuffer()
    }

    private func setupPipeline() {
        let library = EnvironmentVariables.shared.metalLibrary
        
        // Load shaders
        let rgba32FloatFunction = library.makeFunction(name: "planeFragmentShader")
        let r32FloatFunction = library.makeFunction(name: "planeFragmentShaderDepth")
        let r8UnormFunction = library.makeFunction(name: "planeFragmentShaderConfidence")
        let vertexFunction = library.makeFunction(name: "passThroughVertexShader")
        
        // Create pipeline states
        pipelineStateRGBA32Float = createPipelineState(vertexFunction: vertexFunction!, fragmentFunction: rgba32FloatFunction!)
        pipelineStateR32Float = createPipelineState(vertexFunction: vertexFunction!, fragmentFunction: r32FloatFunction!)
        pipelineStateR8Unorm = createPipelineState(vertexFunction: vertexFunction!, fragmentFunction: r8UnormFunction!)
        
    }
    
    private func setupVertexBuffer() {
        let vertices: [Float] = [
            -1.0, -1.0, 0.0, 1.0,
             1.0, -1.0, 0.0, 1.0,
            -1.0,  1.0, 0.0, 1.0,
            -1.0,  1.0, 0.0, 1.0,
             1.0, -1.0, 0.0, 1.0,
             1.0,  1.0, 0.0, 1.0
        ]
        vertexBuffer = device.makeBuffer(bytes: vertices, length: vertices.count * MemoryLayout<Float>.size, options: [])
    }

    private func createPipelineState(vertexFunction: MTLFunction, fragmentFunction: MTLFunction) -> MTLRenderPipelineState? {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.depthAttachmentPixelFormat = .invalid
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        descriptor.vertexDescriptor = createPlaneMetalVertexDescriptor()
        return try? device.makeRenderPipelineState(descriptor: descriptor)
    }
    
    private func createPlaneMetalVertexDescriptor() -> MTLVertexDescriptor {
        let mtlVertexDescriptor: MTLVertexDescriptor = MTLVertexDescriptor()
        // Store position in `attribute[[0]]`.
        mtlVertexDescriptor.attributes[0].format = .float2
        mtlVertexDescriptor.attributes[0].offset = 0
        mtlVertexDescriptor.attributes[0].bufferIndex = 0
        
        // Store texture coordinates in `attribute[[1]]`.
        mtlVertexDescriptor.attributes[1].format = .float2
        mtlVertexDescriptor.attributes[1].offset = 8
        mtlVertexDescriptor.attributes[1].bufferIndex = 0
        
        // Set stride to twice the `float2` bytes per vertex.
        mtlVertexDescriptor.layouts[0].stride = 2 * MemoryLayout<SIMD2<Float>>.stride
        mtlVertexDescriptor.layouts[0].stepRate = 1
        mtlVertexDescriptor.layouts[0].stepFunction = .perVertex
        
        return mtlVertexDescriptor
    }

    func image(from texture: MTLTexture, pixelFormat: MTLPixelFormat) -> UIImage? {
        let commandBuffer = commandQueue.makeCommandBuffer()!
        let ciImage: CIImage?

        switch pixelFormat {
        case .rgba32Float:
            ciImage = processTexture(texture, with: pipelineStateRGBA32Float!, commandBuffer: commandBuffer)
        case .r32Float:
            ciImage = processTexture(texture, with: pipelineStateR32Float!, commandBuffer: commandBuffer)
        case .r8Unorm:
            ciImage = processTexture(texture, with: pipelineStateR8Unorm!, commandBuffer: commandBuffer)
        default:
            ciImage = nil
        }

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        if let ciImage = ciImage {
            let context = CIContext(options: nil)
            if let cgImage = context.createCGImage(ciImage, from: ciImage.extent) {
                return UIImage(cgImage: cgImage)
            }
        }

        return nil
    }

    private func processTexture(_ texture: MTLTexture, with pipelineState: MTLRenderPipelineState, commandBuffer: MTLCommandBuffer) -> CIImage? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: texture.height, height: texture.width, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        guard let outputTexture = device.makeTexture(descriptor: descriptor) else {
            return nil
        }

        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = outputTexture
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        renderPassDescriptor.colorAttachments[0].storeAction = .store

        let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor)!
        renderEncoder.setRenderPipelineState(pipelineState)
        renderEncoder.setFragmentTexture(texture, index: 0)
        renderEncoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        renderEncoder.endEncoding()

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        return CIImage(mtlTexture: outputTexture, options: [CIImageOption.colorSpace: colorSpace])
    }
}
