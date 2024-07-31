func imageFromTexture(texture: MTLTexture, pixelFormat: MTLPixelFormat) -> UIImage? {
        let width = texture.width
        let height = texture.height
        var imageBytes: [UInt8]
        var bytesPerPixel: Int
        var convertedBytes: [UInt8]
        
        switch pixelFormat {
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