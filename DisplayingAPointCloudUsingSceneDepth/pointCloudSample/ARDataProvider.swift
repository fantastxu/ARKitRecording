/*
See LICENSE folder for this sample’s licensing information.

Abstract:
A utility class that provides processed depth information.
*/

import Foundation
import SwiftUI
import Combine
import ARKit
import Accelerate
import MetalPerformanceShaders
import SwiftUI
import MetalKit
import UIKit

// Wrap the `MTLTexture` protocol to reference outputs from ARKit.
final class MetalTextureContent {
    var texture: MTLTexture?
}

// Enable `CVPixelBuffer` to output an `MTLTexture`.
extension CVPixelBuffer {
    
    func texture(withFormat pixelFormat: MTLPixelFormat, planeIndex: Int, addToCache cache: CVMetalTextureCache) -> MTLTexture? {
        
        let width = CVPixelBufferGetWidthOfPlane(self, planeIndex)
        let height = CVPixelBufferGetHeightOfPlane(self, planeIndex)
        
        var cvtexture: CVMetalTexture?
        _ = CVMetalTextureCacheCreateTextureFromImage(nil, cache, self, nil, pixelFormat, width, height, planeIndex, &cvtexture)
        let texture = CVMetalTextureGetTexture(cvtexture!)
        
        return texture
        
    }
    
}

final class ARDataCache{
    public var rgbTexture: MTLTexture?
    public var depthTexture: MTLTexture?
    public var confiTexture: MTLTexture?
    public var transform: simd_float4x4?
    public var timeStamp: TimeInterval?
    public var intrinsics: simd_float3x3?
    
}

// Collect AR data using a lower-level receiver. This class converts AR data
// to a Metal texture, optionally upscaling depth data using a guided filter,
// and implements `ARDataReceiver` to respond to `onNewARData` events.
final class ARProvider: ObservableObject,ARDataReceiver {
    // Set the destination resolution for the upscaled algorithm.
    let upscaledWidth = 960
    let upscaledHeight = 760
    
    // Set the original depth size.
    let origDepthWidth = 256
    let origDepthHeight = 192
    
    // Set the original color size.
    let origColorWidth = 1920
    let origColorHeight = 1440
    
    // Set the guided filter constants.
    let guidedFilterEpsilon: Float = 0.004
    let guidedFilterKernelDiameter = 5
    
    let arReceiver = ARReceiver()
    var lastArData: ARData?
    let depthContent = MetalTextureContent()
    let confidenceContent = MetalTextureContent()
    let colorYContent = MetalTextureContent()
    let colorCbCrContent = MetalTextureContent()
    let upscaledCoef = MetalTextureContent()
    let downscaledRGB = MetalTextureContent()
    let upscaledConfidence = MetalTextureContent()
    
    let coefTexture: MTLTexture
    let destDepthTexture: MTLTexture
    let destConfTexture: MTLTexture
    let colorRGBTexture: MTLTexture
    let colorRGBTextureDownscaled: MTLTexture
    let colorRGBTextureDownscaledLowRes: MTLTexture
    
    
    
    // Enable or disable depth upsampling.
    public var isToUpsampleDepth: Bool = true {
        didSet {
            processLastArData()
        }
    }
    
    // Enable or disable smoothed-depth upsampling.
    public var isUseSmoothedDepthForUpsampling: Bool = false {
        didSet {
            processLastArData()
        }
    }
    
    
    public var fps: Float = 10 {didSet{}}
    private let processingQueue = DispatchQueue(label: "processingQueue", qos: .userInitiated, attributes: .concurrent)
    private let queueSync = DispatchQueue(label: "arDataCacheQueueSync",qos: .userInitiated, attributes: .concurrent)
    private let convertQueueSync = DispatchQueue(label: "arDataConvertQueueSync",qos: .userInitiated, attributes: .concurrent)
    private let convertingQueue = DispatchQueue(label: "convertingQueue", qos: .userInitiated, attributes: .concurrent)
    private var cancellables = Set<AnyCancellable>()
    //private let semaphore = DispatchSemaphore(value: 0)
    
    private let saveThreadCount = 5
    private var convertThreadCount = 0
    private var arDataCacheQueue: [ARDataCache] = []
    
    var saveActiveThreads = 0
    @Published public var convertActiveThreaqds = 0
    @Published public var arDataConvertQueue: [String] = []
    
    var textureCache: CVMetalTextureCache?
    let metalDevice: MTLDevice
    let guidedFilter: MPSImageGuidedFilter?
    let mpsScaleFilter: MPSImageBilinearScale?
    let commandQueue: MTLCommandQueue
    let pipelineStateCompute: MTLComputePipelineState?
    var recordStartTime : TimeInterval
    var depthFolderURL : URL
    var depthRawFolderURL: URL
    var poseFolderURL : URL
    var confidenceFolderURL : URL
    var confidenceRawFolderURL : URL
    var rgbFolderURL : URL
    var rgbRawFolderURL : URL
    var intrinsicsFolderURL : URL
    
    
    // Create an empty texture.
    static func createTexture(metalDevice: MTLDevice, width: Int, height: Int, usage: MTLTextureUsage, pixelFormat: MTLPixelFormat) -> MTLTexture {
        let descriptor: MTLTextureDescriptor = MTLTextureDescriptor()
        descriptor.pixelFormat = pixelFormat
        descriptor.width = width
        descriptor.height = height
        descriptor.usage = usage
        let resTexture = metalDevice.makeTexture(descriptor: descriptor)
        return resTexture!
    }
    
    // Start or resume the stream from ARKit.
    func start() {
        arReceiver.start()
    }
    
    // Pause the stream from ARKit.
    func pause() {
        arReceiver.pause()
    }
    
    func record(){
        if(arDataCacheQueue.count > 0){
            return;}
        
        guard (lastArData?.timeStamp) != nil else { return }
        
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMdd_HHmmss"
        let mainFolderName = dateFormatter.string(from: Date())
        let fileManager = FileManager.default
        let documentDirectory = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        let mainFolderURL = documentDirectory.appendingPathComponent(mainFolderName)
        depthFolderURL = mainFolderURL.appendingPathComponent("depth")
        depthRawFolderURL = mainFolderURL.appendingPathComponent("depth_RAW")
        poseFolderURL = mainFolderURL.appendingPathComponent("pose")
        confidenceFolderURL = mainFolderURL.appendingPathComponent("confidence")
        confidenceRawFolderURL = mainFolderURL.appendingPathComponent("confidence_RAW")
        rgbFolderURL = mainFolderURL.appendingPathComponent("rgb")
        rgbRawFolderURL = mainFolderURL.appendingPathComponent("rgb_RAW")
        intrinsicsFolderURL = mainFolderURL.appendingPathComponent("intrinsics")

        do {
            try fileManager.createDirectory(at: mainFolderURL, withIntermediateDirectories: true, attributes: nil)
            print("Main directory created at \(mainFolderURL.path)")
        } catch {
            print("Error creating main directory: \(error)")
        }
      
        do {
            try fileManager.createDirectory(at: rgbFolderURL, withIntermediateDirectories: true, attributes: nil)
            print("RGB directory created at \(rgbFolderURL.path)")
        } catch {
            print("Error creating RGB directory: \(error)")
        }
        
        do {
            try fileManager.createDirectory(at: rgbRawFolderURL, withIntermediateDirectories: true, attributes: nil)
            print("RGB_Raw directory created at \(rgbRawFolderURL.path)")
        } catch {
            print("Error creating RGB_Raw directory: \(error)")
        }

        do {
            try fileManager.createDirectory(at: depthFolderURL, withIntermediateDirectories: true, attributes: nil)
            print("Depth directory created at \(depthFolderURL.path)")
        } catch {
            print("Error creating Depth directory: \(error)")
        }
        
        do {
            try fileManager.createDirectory(at: depthRawFolderURL, withIntermediateDirectories: true, attributes: nil)
            print("Depth_Raw directory created at \(depthRawFolderURL.path)")
        } catch {
            print("Error creating Depth_Raw directory: \(error)")
        }

        do {
            try fileManager.createDirectory(at: poseFolderURL, withIntermediateDirectories: true, attributes: nil)
            print("Pose directory created at \(poseFolderURL.path)")
        } catch {
            print("Error creating Pose directory: \(error)")
        }

        do {
            try fileManager.createDirectory(at: confidenceFolderURL, withIntermediateDirectories: true, attributes: nil)
            print("Confidence directory created at \(confidenceFolderURL.path)")
        } catch {
            print("Error creating Confidence directory: \(error)")
        }
        
        do {
            try fileManager.createDirectory(at: confidenceRawFolderURL, withIntermediateDirectories: true, attributes: nil)
            print("Confidence_Raw directory created at \(confidenceRawFolderURL.path)")
        } catch {
            print("Error creating Confidence_Raw directory: \(error)")
        }
        
        do {
            try fileManager.createDirectory(at: intrinsicsFolderURL, withIntermediateDirectories: true, attributes: nil)
            print("Intrinsics directory created at \(intrinsicsFolderURL.path)")
        } catch {
            print("Error creating Intrinsics directory: \(error)")
        }
        
        //write Raw data info
        if let rgbtex = downscaledRGB.texture {
            var metaURL = rgbRawFolderURL.appendingPathComponent("0.meta").appendingPathExtension("txt")
            do{
                try "\(rgbtex.width)x\(rgbtex.height)x\(getPixelFormatBytes(pixelFormat: rgbtex.pixelFormat))".write(to:metaURL,atomically: true, encoding: .utf8)}
            catch{
                print("Write rgb texture meta info error!")
            }
        }
        
        if let depthtex = depthContent.texture {
            var metaURL = depthRawFolderURL.appendingPathComponent("0.meta").appendingPathExtension("txt")
            do{
                try "\(depthtex.width)x\(depthtex.height)x\(getPixelFormatBytes(pixelFormat: depthtex.pixelFormat))".write(to:metaURL,atomically: true, encoding: .utf8)}
            catch{
                print("Write depth texture meta info error!")
            }
        }
        
        if let confitex = confidenceContent.texture {
            var metaURL = confidenceRawFolderURL.appendingPathComponent("0.meta").appendingPathExtension("txt")
            do{
                try "\(confitex.width)x\(confitex.height)x\(getPixelFormatBytes(pixelFormat: confitex.pixelFormat))".write(to:metaURL,atomically: true, encoding: .utf8)}
            catch{
                print("Write confidence texture meta info error!")
            }
        }

        recordStartTime = 0.0
        convertThreadCount = 0
    }
    
    func stop(){
        recordStartTime = -1.0
        convertThreadCount = 5
    }
    
    func getPixelFormatBytes(pixelFormat:MTLPixelFormat) -> Int {
        switch pixelFormat {
        case .rgba8Unorm, .bgra8Unorm:
            return 4
        case .r8Unorm:
            return 1
        case .r32Float:
            return 4
        case .rgba32Float:
            return 16
        // 添加其他支持的像素格式
        default:
            return 0
        }
    }
    
    // Initialize the MPS filters, metal pipeline, and Metal textures.
    init() {
        do {
            metalDevice = EnvironmentVariables.shared.metalDevice
            CVMetalTextureCacheCreate(nil, nil, metalDevice, nil, &textureCache)
            guidedFilter = MPSImageGuidedFilter(device: metalDevice, kernelDiameter: guidedFilterKernelDiameter)
            guidedFilter?.epsilon = guidedFilterEpsilon
            mpsScaleFilter = MPSImageBilinearScale(device: metalDevice)
            commandQueue = EnvironmentVariables.shared.metalCommandQueue
            let lib = EnvironmentVariables.shared.metalLibrary
            let convertYUV2RGBFunc = lib.makeFunction(name: "convertYCbCrToRGBA")
            pipelineStateCompute = try metalDevice.makeComputePipelineState(function: convertYUV2RGBFunc!)
            // Initialize the working textures.
            coefTexture = ARProvider.createTexture(metalDevice: metalDevice, width: origDepthWidth, height: origDepthHeight,
                                                   usage: [.shaderRead, .shaderWrite], pixelFormat: .rgba32Float)
            destDepthTexture = ARProvider.createTexture(metalDevice: metalDevice, width: upscaledWidth, height: upscaledHeight,
                                                        usage: [.shaderRead, .shaderWrite], pixelFormat: .r32Float)
            destConfTexture = ARProvider.createTexture(metalDevice: metalDevice, width: upscaledWidth, height: upscaledHeight,
                                                       usage: [.shaderRead, .shaderWrite], pixelFormat: .r8Unorm)
            colorRGBTexture = ARProvider.createTexture(metalDevice: metalDevice, width: origColorWidth, height: origColorHeight,
                                                       usage: [.shaderRead, .shaderWrite], pixelFormat: .rgba32Float)
            colorRGBTextureDownscaled = ARProvider.createTexture(metalDevice: metalDevice, width: upscaledWidth, height: upscaledHeight,
                                                                 usage: [.shaderRead, .shaderWrite], pixelFormat: .rgba32Float)
            colorRGBTextureDownscaledLowRes = ARProvider.createTexture(metalDevice: metalDevice, width: origDepthWidth, height: origDepthHeight,
                                                                       usage: [.shaderRead, .shaderWrite], pixelFormat: .rgba32Float)
            upscaledCoef.texture = coefTexture
            upscaledConfidence.texture = destConfTexture
            downscaledRGB.texture = colorRGBTextureDownscaled
            recordStartTime = -1.0
            
            rgbFolderURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            depthFolderURL  = rgbFolderURL
            poseFolderURL   = rgbFolderURL
            confidenceFolderURL   = rgbFolderURL
            depthRawFolderURL = rgbFolderURL
            confidenceRawFolderURL = rgbFolderURL
            intrinsicsFolderURL = rgbFolderURL
            rgbRawFolderURL = rgbFolderURL
            // Set the delegate for ARKit callbacks.
            
            
            arReceiver.delegate = self
            
            //self.processCache()
            
        } catch {
            fatalError("Unexpected error: \(error).")
        }
    }
    
    // Save a reference to the current AR data and process it.
    func onNewARData(arData: ARData) {
        lastArData = arData
        processLastArData()
        queueSync.async(flags: .barrier) {
            if(self.arDataCacheQueue.count > 0)
            {
                self.processCache()
            }
                
        }
        
        convertQueueSync.async {
            if(self.arDataConvertQueue.count > 0 && self.convertActiveThreaqds < self.convertThreadCount)
            {
                guard let filename = self.arDataConvertQueue.first else {
                    return
                }
                
                self.arDataConvertQueue.removeFirst()
                self.convertActiveThreaqds += 1
                self.convertData(filename: filename)
                    
            }
        }
        
    }
    
    // Copy the AR data to Metal textures and, if the user enables the UI, upscale the depth using a guided filter.
    func processLastArData() {
        colorYContent.texture = lastArData?.colorImage?.texture(withFormat: .r8Unorm, planeIndex: 0, addToCache: textureCache!)!
        colorCbCrContent.texture = lastArData?.colorImage?.texture(withFormat: .rg8Unorm, planeIndex: 1, addToCache: textureCache!)!
        
        if isUseSmoothedDepthForUpsampling {
            depthContent.texture = lastArData?.depthSmoothImage?.texture(withFormat: .r32Float, planeIndex: 0, addToCache: textureCache!)!
            confidenceContent.texture = lastArData?.confidenceSmoothImage?.texture(withFormat: .r8Unorm, planeIndex: 0, addToCache: textureCache!)!
        } else {
            depthContent.texture = lastArData?.depthImage?.texture(withFormat: .r32Float, planeIndex: 0, addToCache: textureCache!)!
            confidenceContent.texture = lastArData?.confidenceImage?.texture(withFormat: .r8Unorm, planeIndex: 0, addToCache: textureCache!)!
        }
        if isToUpsampleDepth {
            guard let cmdBuffer = commandQueue.makeCommandBuffer() else { return }
            guard let computeEncoder = cmdBuffer.makeComputeCommandEncoder() else { return }
            // Convert YUV to RGB because the guided filter needs RGB format.
            computeEncoder.setComputePipelineState(pipelineStateCompute!)
            computeEncoder.setTexture(colorYContent.texture, index: 0)
            computeEncoder.setTexture(colorCbCrContent.texture, index: 1)
            computeEncoder.setTexture(colorRGBTexture, index: 2)
            let threadgroupSize = MTLSizeMake(pipelineStateCompute!.threadExecutionWidth,
                                              pipelineStateCompute!.maxTotalThreadsPerThreadgroup / pipelineStateCompute!.threadExecutionWidth, 1)
            let threadgroupCount = MTLSize(width: Int(ceil(Float(colorRGBTexture.width) / Float(threadgroupSize.width))),
                                           height: Int(ceil(Float(colorRGBTexture.height) / Float(threadgroupSize.height))),
                                           depth: 1)
            computeEncoder.dispatchThreadgroups(threadgroupCount, threadsPerThreadgroup: threadgroupSize)
            computeEncoder.endEncoding()
            
            // Downscale the RGB data. Pass in the target resoultion.
            mpsScaleFilter?.encode(commandBuffer: cmdBuffer, sourceTexture: colorRGBTexture,
                                   destinationTexture: colorRGBTextureDownscaled)
            // Match the input depth resolution.
            mpsScaleFilter?.encode(commandBuffer: cmdBuffer, sourceTexture: colorRGBTexture,
                                   destinationTexture: colorRGBTextureDownscaledLowRes)
            
            // Upscale the confidence data. Pass in the target resolution.
            mpsScaleFilter?.encode(commandBuffer: cmdBuffer, sourceTexture: confidenceContent.texture!,
                                   destinationTexture: destConfTexture)
            
            // Encode the guided filter.
            guidedFilter?.encodeRegression(to: cmdBuffer, sourceTexture: depthContent.texture!,
                                           guidanceTexture: colorRGBTextureDownscaledLowRes, weightsTexture: nil,
                                           destinationCoefficientsTexture: coefTexture)
            
            // Optionally, process `coefTexture` here.
            
            guidedFilter?.encodeReconstruction(to: cmdBuffer, guidanceTexture: colorRGBTextureDownscaled,
                                               coefficientsTexture: coefTexture, destinationTexture: destDepthTexture)
            
            
            if(recordStartTime >= 0.0 && ((lastArData?.timeStamp) != nil))
            {
                if(lastArData!.timeStamp - recordStartTime > Double(1 / self.fps))
                {
                    let newcache = ARDataCache()
                    copyTextureCommand(sourceTexture: &newcache.rgbTexture, destTexture: downscaledRGB.texture!, cmdBuffer: cmdBuffer)
                    copyTextureCommand(sourceTexture: &newcache.depthTexture, destTexture: destDepthTexture, cmdBuffer: cmdBuffer)
                    copyTextureCommand(sourceTexture: &newcache.confiTexture, destTexture: confidenceContent.texture!, cmdBuffer: cmdBuffer)
                    
                    newcache.transform = lastArData!.cameraTransform
                    newcache.intrinsics = lastArData!.cameraIntrinsics
                    newcache.timeStamp = lastArData?.timeStamp
                    addToQueue(newcache)
                    recordStartTime = self.lastArData!.timeStamp
                    
                    
                    print("Data remaining count:\(arDataCacheQueue.count)")

                }
            }
            
            cmdBuffer.commit()
            
            // Override the original depth texture with the upscaled version.
            depthContent.texture = destDepthTexture
        }
        
        

    }
    
    


    // 函数：将 ARDataCache 对象添加到队列
    func addToQueue(_ cache: ARDataCache) {
        queueSync.async(flags: .barrier) {
            self.arDataCacheQueue.append(cache)
        }
    }
    
    func processCache() {
        processingQueue.async {
            if(self.saveActiveThreads < self.saveThreadCount) {
                self.saveActiveThreads += 1
                print("=========>saveActiveThreads:\(self.saveActiveThreads)")
                self.processFromQueue()
            }
        }
    }
    
    func convertData(filename:String)
    {
        convertingQueue.async {
            self.processFromFile(filename: filename)
        }
        
    }
    
    func processFromFile(filename:String)
    {
        let rgbURL = rgbRawFolderURL.appendingPathComponent(filename).appendingPathExtension("bytes")
        if let rgbtex = loadTextureFromFile(device: metalDevice, fileURL: rgbURL, width: downscaledRGB.texture!.width, height: downscaledRGB.texture!.height, bytesPerPixel: getPixelFormatBytes(pixelFormat: downscaledRGB.texture!.pixelFormat), pixelFormatRawValue: downscaledRGB.texture!.pixelFormat.rawValue)
        {
            saveTextureAsJPG(texture: rgbtex, pixelFormat: rgbtex.pixelFormat, directoryURL: rgbFolderURL, fileName: filename)
        }
        
        let depthURL = depthRawFolderURL.appendingPathComponent(filename).appendingPathExtension("bytes")
        if let depthtex = loadTextureFromFile(device: metalDevice, fileURL: depthURL, width: depthContent.texture!.width, height: depthContent.texture!.height, bytesPerPixel: getPixelFormatBytes(pixelFormat: depthContent.texture!.pixelFormat), pixelFormatRawValue: depthContent.texture!.pixelFormat.rawValue)
        {
            saveTextureAsJPG(texture: depthtex, pixelFormat: depthtex.pixelFormat, directoryURL: depthFolderURL, fileName: filename)
        }
        
        let confiURL = confidenceRawFolderURL.appendingPathComponent(filename).appendingPathExtension("bytes")
        if let confitex = loadTextureFromFile(device: metalDevice, fileURL: confiURL, width: confidenceContent.texture!.width, height: confidenceContent.texture!.height, bytesPerPixel: getPixelFormatBytes(pixelFormat: confidenceContent.texture!.pixelFormat), pixelFormatRawValue: confidenceContent.texture!.pixelFormat.rawValue)
        {
            saveTextureAsJPG(texture: confitex, pixelFormat: confitex.pixelFormat, directoryURL: confidenceFolderURL, fileName: filename)
        }
        
        
        convertQueueSync.async(flags:.barrier) {
            self.convertActiveThreaqds -= 1
        }
    }
    
    func loadTextureFromFile(device: MTLDevice, fileURL: URL, width: Int, height: Int, bytesPerPixel: Int, pixelFormatRawValue: UInt) -> MTLTexture? {
        do {
            let data = try Data(contentsOf: fileURL)
            let buffer = [UInt8](data)
            
            guard let pixelFormat = MTLPixelFormat(rawValue: pixelFormatRawValue) else {
                print("Invalid file name format")
                return nil
            }
            
            // 创建纹理描述符
            let textureDescriptor = MTLTextureDescriptor()
            textureDescriptor.pixelFormat = pixelFormat
            textureDescriptor.width = width
            textureDescriptor.height = height
            textureDescriptor.usage = .shaderRead
            
            // 创建纹理
            guard let texture = device.makeTexture(descriptor: textureDescriptor) else {
                print("Failed to create texture")
                return nil
            }
            
            
            let bytesPerRow = bytesPerPixel * width
            
            // 将数据拷贝到纹理
            buffer.withUnsafeBytes { ptr in
                texture.replace(region: MTLRegionMake2D(0, 0, width, height),
                                mipmapLevel: 0,
                                withBytes: ptr.baseAddress!,
                                bytesPerRow: bytesPerRow)
            }
            
            return texture
            
        } catch {
            print("Failed to load texture from file: \(error)")
            return nil
        }
    }
    

    // 函数：从队列中取出 ARDataCache 对象并处理
    func processFromQueue() {
        while true {
            
            var cacheToProcess: ARDataCache?
            
            queueSync.sync(flags: .barrier) {
                if !arDataCacheQueue.isEmpty {
                    cacheToProcess = arDataCacheQueue.removeFirst()
                }

            }
            
            if let cache = cacheToProcess {
                // Save raw data to files first
                print("Processing ARDataCache with timestamp: \(String(describing: cache.timeStamp))")
                let filename = String(format: "%.9f",cache.timeStamp!)
                
                if(cache.rgbTexture != nil)
                {
                    //self.saveTextureAsJPG(texture: cache.rgbTexture!, pixelFormat: .rgba32Float, directoryURL: self.rgbFolderURL, fileName: filename)
                    self.saveTextureToFile(texture: cache.rgbTexture!, directoryURL: self.rgbRawFolderURL, fileName: filename)
                }

                
                if(cache.depthTexture != nil)
                {
                    //self.saveTextureAsJPG(texture: cache.depthTexture!, pixelFormat: .r32Float, directoryURL: self.depthFolderURL, fileName: filename)
                    
                    self.saveTextureToFile(texture: cache.depthTexture!, directoryURL: self.depthRawFolderURL, fileName: filename)
                }

                
                if(cache.confiTexture != nil)
                {
                    //self.saveTextureAsJPG(texture: cache.confiTexture!, pixelFormat: .r8Unorm, directoryURL: self.confidenceFolderURL, fileName: filename)
                    
                    self.saveTextureToFile(texture: cache.confiTexture!, directoryURL: self.confidenceRawFolderURL, fileName: filename)
                }

                
                self.saveMatrixToFile(matrix: cache.transform!, directoryURL: self.poseFolderURL, fileName: filename)
                
                self.saveMatrixToFile(matrix: cache.intrinsics!, directoryURL: self.intrinsicsFolderURL, fileName: filename)

                cache.confiTexture = nil
                cache.depthTexture = nil
                cache.rgbTexture = nil
                
                //add filename to
                convertQueueSync.sync{
                    arDataConvertQueue.append(filename)
                }
                            
            }
            else{
                break
            }
        }
        
        processingQueue.async(flags: .barrier){
            self.saveActiveThreads -= 1
            print("=========>saveActiveThreads:\(self.saveActiveThreads)")
        }

    }
    
    func copyTextureCommand(sourceTexture: inout MTLTexture?, destTexture:MTLTexture, cmdBuffer:MTLCommandBuffer){
        sourceTexture = ARProvider.createTexture(metalDevice: metalDevice, width: destTexture.width, height: destTexture.height, usage: [.shaderRead, .shaderWrite], pixelFormat: destTexture.pixelFormat)
        // 创建 Blit Encoder
        guard let blitEncoder = cmdBuffer.makeBlitCommandEncoder() else {
            fatalError("Unable to create blit command encoder")
        }

        // 复制纹理
        blitEncoder.copy(from: destTexture,
                         sourceSlice: 0,
                         sourceLevel: 0,
                         sourceOrigin: MTLOriginMake(0, 0, 0),
                         sourceSize: MTLSizeMake(destTexture.width, destTexture.height, destTexture.depth),
                         to: sourceTexture!,
                         destinationSlice: 0,
                         destinationLevel: 0,
                         destinationOrigin: MTLOriginMake(0, 0, 0))
        
        blitEncoder.endEncoding()
    }
    
    func clamp<T: Comparable>(_ value: T, min: T, max: T) -> T {
        if value < min { return min }
        if value > max { return max }
        return value
    }
    
    func getJetColorsFromNormalizedVal(_ val: Float) -> [UInt8] {
        var res: [Float] = [0, 0, 0, 1]
        if val > 0.01 {
            res[0] = 1.5 - abs(4.0 * val - 3.0)
            res[1] = 1.5 - abs(4.0 * val - 2.0)
            res[2] = 1.5 - abs(4.0 * val - 1.0)
        }
        res = res.map { clamp($0, min: 0.0, max: 1.0) }
        return [UInt8(res[0] * 255), UInt8(res[1] * 255), UInt8(res[2] * 255)]
    }
    
    func imageFromTexture(texture: MTLTexture, pixelFormat: MTLPixelFormat) -> UIImage? {
        let width = texture.width
        let height = texture.height
        var imageBytes: [UInt8]
        var bytesPerPixel: Int
        var convertedBytes: [UInt8]
        
        switch pixelFormat {
        case .rgba8Unorm:
            bytesPerPixel = 4
            let imageByteCount = width * height * bytesPerPixel
            imageBytes = [UInt8](repeating: 0, count: imageByteCount)
            let region = MTLRegionMake2D(0, 0, width, height)
            texture.getBytes(&imageBytes, bytesPerRow: width * bytesPerPixel, from: region, mipmapLevel: 0)
            convertedBytes = imageBytes
        case .rgba32Float:
            bytesPerPixel = 16
            let imageByteCount = width * height * bytesPerPixel
            imageBytes = [UInt8](repeating: 0, count: imageByteCount)
            let region = MTLRegionMake2D(0, 0, width, height)
            texture.getBytes(&imageBytes, bytesPerRow: width * bytesPerPixel, from: region, mipmapLevel: 0)
            convertedBytes = [UInt8](repeating: 0, count: width * height * 4)
            for i in 0..<width * height {
                let r = min(max(Float32(bitPattern: UInt32(imageBytes[i * 16..<i * 16 + 4].withUnsafeBytes { $0.load(as: UInt32.self) })), 0.0), 1.0)
                let g = min(max(Float32(bitPattern: UInt32(imageBytes[i * 16 + 4..<i * 16 + 8].withUnsafeBytes { $0.load(as: UInt32.self) })), 0.0), 1.0)
                let b = min(max(Float32(bitPattern: UInt32(imageBytes[i * 16 + 8..<i * 16 + 12].withUnsafeBytes { $0.load(as: UInt32.self) })), 0.0), 1.0)
                let a = min(max(Float32(bitPattern: UInt32(imageBytes[i * 16 + 12..<i * 16 + 16].withUnsafeBytes { $0.load(as: UInt32.self) })), 0.0), 1.0)
                convertedBytes[i * 4] = UInt8(r * 255.0)
                convertedBytes[i * 4 + 1] = UInt8(g * 255.0)
                convertedBytes[i * 4 + 2] = UInt8(b * 255.0)
                convertedBytes[i * 4 + 3] = UInt8(a * 255.0)
            }
        case .r32Float:
            bytesPerPixel = 4
            let imageByteCount = width * height * bytesPerPixel
            imageBytes = [UInt8](repeating: 0, count: imageByteCount)
            let region = MTLRegionMake2D(0, 0, width, height)
            texture.getBytes(&imageBytes, bytesPerRow: width * bytesPerPixel, from: region, mipmapLevel: 0)
            convertedBytes = [UInt8](repeating: 0, count: width * height * 4)
            for i in 0..<width * height {
                let r = min(max(Float32(bitPattern: UInt32(imageBytes[i * 4..<i * 4 + 4].withUnsafeBytes { $0.load(as: UInt32.self) })), 0.0), 2.5)
                let normalizedVal = r / 2.5
                let jetColor = getJetColorsFromNormalizedVal(normalizedVal)
                convertedBytes[i * 4] = jetColor[0]
                convertedBytes[i * 4 + 1] = jetColor[1]
                convertedBytes[i * 4 + 2] = jetColor[2]
                convertedBytes[i * 4 + 3] = 255
            }
        case .r8Unorm:
            bytesPerPixel = 1
            let imageByteCount = width * height * bytesPerPixel
            imageBytes = [UInt8](repeating: 0, count: imageByteCount)
            let region = MTLRegionMake2D(0, 0, width, height)
            texture.getBytes(&imageBytes, bytesPerRow: width * bytesPerPixel, from: region, mipmapLevel: 0)
            convertedBytes = [UInt8](repeating: 0, count: width * height * 4)
            for i in 0..<width * height {
                let r = imageBytes[i]
                let res = round(255.0 * Float(r) / 255.0)
                let resI = Int(res)
                if resI == 0 {
                    convertedBytes[i * 4] = 255
                    convertedBytes[i * 4 + 1] = 0
                    convertedBytes[i * 4 + 2] = 0
                    convertedBytes[i * 4 + 3] = 255
                } else if (resI == 1) {
                    convertedBytes[i * 4] = 0
                    convertedBytes[i * 4 + 1] = 255
                    convertedBytes[i * 4 + 2] = 0
                    convertedBytes[i * 4 + 3] = 255
                } else if (resI == 2) {
                    convertedBytes[i * 4] = 0
                    convertedBytes[i * 4 + 1] = 0
                    convertedBytes[i * 4 + 2] = 255
                    convertedBytes[i * 4 + 3] = 255
                } else {
                    convertedBytes[i * 4] = 0
                    convertedBytes[i * 4 + 1] = 0
                    convertedBytes[i * 4 + 2] = 0
                    convertedBytes[i * 4 + 3] = 255
                }
            }
        default:
            print("Unsupported pixel format")
            return nil
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        
        if let dataProvider = CGDataProvider(data: NSData(bytes: &convertedBytes, length: convertedBytes.count)) {
            if let cgImage = CGImage(width: width,
                                     height: height,
                                     bitsPerComponent: 8,
                                     bitsPerPixel: 32,
                                     bytesPerRow: width * 4,
                                     space: colorSpace,
                                     bitmapInfo: bitmapInfo,
                                     provider: dataProvider,
                                     decode: nil,
                                     shouldInterpolate: false,
                                     intent: .defaultIntent) {
                let rotatedCGImage = cgImageRotated90DegreesCounterClockwise(cgImage)
                return UIImage(cgImage: rotatedCGImage)
            }
        }
        return nil
    }

    func saveImageAsJPG(image: UIImage, fileURL: URL) -> Bool {
        return autoreleasepool{
            guard let data = image.jpegData(compressionQuality: 1.0) else {
                return false
            }
            do {
                try data.write(to: fileURL)
                return true
            } catch {
                print("Error saving image: \(error)")
                return false
            }
        }

    }
    
    func cgImageRotated90DegreesCounterClockwise(_ image: CGImage) -> CGImage {
        let width = image.width
        let height = image.height

        var transform = CGAffineTransform.identity
        transform = transform.translatedBy(x: 0, y: CGFloat(width))
        transform = transform.rotated(by: -.pi / 2)

        let context = CGContext(data: nil,
                                width: height,
                                height: width,
                                bitsPerComponent: image.bitsPerComponent,
                                bytesPerRow: width * 4, // Adjust bytesPerRow for the original dimensions
                                space: image.colorSpace!,
                                bitmapInfo: image.bitmapInfo.rawValue)!

        context.concatenate(transform)
        context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))) // Draw in the original dimensions

        return context.makeImage()!
    }
    
    func saveTextureAsJPG(texture: MTLTexture, pixelFormat: MTLPixelFormat, directoryURL: URL, fileName: String) {

            if let image = self.imageFromTexture(texture: texture, pixelFormat: pixelFormat) {
                let fileURL = directoryURL.appendingPathComponent(fileName).appendingPathExtension("jpg")
                if self.saveImageAsJPG(image: image, fileURL: fileURL) {
                    print("Image saved successfully at \(fileURL)")
                } else {
                    print("Failed to save image.")
                }
            } else {
                print("Failed to convert texture to image.")
            }
        }
    
    func vectorToString(vector: SCNVector4) -> String {
        return "x: \(vector.x), y: \(vector.y), z: \(vector.z), w: \(vector.w)"
    }

    func writeVectorToFile(vector: SCNVector4, directoryURL: URL, fileName: String) {

        let fileURL = directoryURL.appendingPathComponent(fileName).appendingPathExtension("txt")
        let vectorString = vectorToString(vector: vector)
        
        do {
            try vectorString.write(to: fileURL, atomically: true, encoding: .utf8)
            print("Successfully wrote to file at \(fileURL.path)")
        } catch {
            print("Failed to write to file: \(error)")
        }
        
    }
    
    func saveTextureToFile(texture: MTLTexture, directoryURL: URL, fileName: String) {
        autoreleasepool{
            let width = texture.width
            let height = texture.height
            let pixelFormat = texture.pixelFormat

            // 计算每行字节数
            let bytesPerPixel = getPixelFormatBytes(pixelFormat: pixelFormat)

            let bytesPerRow = bytesPerPixel * width
            let bufferSize = bytesPerRow * height
            let fileURL = directoryURL.appendingPathComponent(fileName).appendingPathExtension("bytes")
            
            
            // 创建一个缓冲区来存储纹理数据
            var buffer = [UInt8](repeating: 0, count: bufferSize)

            // 拷贝纹理数据到缓冲区
            texture.getBytes(&buffer, bytesPerRow: bytesPerRow, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)

            // 将缓冲区写入文件
            let data = Data(buffer)
            do {
                
                try data.write(to: fileURL)
                print("Texture saved to \(fileURL)")
            } catch {
                print("Failed to save texture to file: \(error)")
            }
        }

        
    }

    func saveMatrixToFile(matrix: simd_float4x4, directoryURL: URL, fileName: String) {
        // 将矩阵的元素格式化为字符串
        var matrixString = ""
        for row in 0..<4 {
            for col in 0..<4 {
                matrixString += "\(matrix[row, col])"
                if col < 3 {
                    matrixString += ", "
                }
            }
            matrixString += "\n"
        }

        // 将字符串写入文件
        let fileURL = directoryURL.appendingPathComponent(fileName).appendingPathExtension("txt")
        do {
            try matrixString.write(to: fileURL, atomically: true, encoding: .utf8)
            print("Matrix saved to \(fileURL)")
        } catch {
            print("Failed to save matrix to file: \(error)")
        }
    }
    
    func saveMatrixToFile(matrix: simd_float3x3, directoryURL: URL, fileName: String)
    {
        // 将矩阵的元素格式化为字符串
        var matrixString = ""
        for row in 0..<3 {
            for col in 0..<3 {
                matrixString += "\(matrix[row, col])"
                if col < 2 {
                    matrixString += ", "
                }
            }
            matrixString += "\n"
        }

        // 将字符串写入文件
        let fileURL = directoryURL.appendingPathComponent(fileName).appendingPathExtension("txt")
        do {
            try matrixString.write(to: fileURL, atomically: true, encoding: .utf8)
            print("Matrix saved to \(fileURL)")
        } catch {
            print("Failed to save matrix to file: \(error)")
        }
    }
}
