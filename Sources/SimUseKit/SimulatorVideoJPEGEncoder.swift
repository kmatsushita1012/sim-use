// SPDX-License-Identifier: Apache-2.0
import CoreGraphics
import CoreVideo
import ImageIO
import Foundation

enum SimulatorVideoJPEGEncoder {
    static func encode(
        pixelBuffer: CVPixelBuffer,
        scale: Double,
        quality: Int
    ) -> Data? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard width > 0,
              height > 0,
              let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer),
              let sourceContext = CGContext(
                  data: baseAddress,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: bytesPerRow,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo(
                      rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                          | CGBitmapInfo.byteOrder32Little.rawValue
                  ).rawValue
              ),
              let sourceImage = sourceContext.makeImage() else {
            return nil
        }

        let outputImage: CGImage
        if scale == 1 {
            outputImage = sourceImage
        } else {
            let outputWidth = max(Int((Double(width) * scale).rounded()), 1)
            let outputHeight = max(Int((Double(height) * scale).rounded()), 1)
            let outputBytesPerRow = outputWidth * 4
            var outputData = Data(count: outputBytesPerRow * outputHeight)

            guard let image = outputData.withUnsafeMutableBytes({ rawBuffer -> CGImage? in
                guard let baseAddress = rawBuffer.baseAddress,
                      let context = CGContext(
                          data: baseAddress,
                          width: outputWidth,
                          height: outputHeight,
                          bitsPerComponent: 8,
                          bytesPerRow: outputBytesPerRow,
                          space: CGColorSpaceCreateDeviceRGB(),
                          bitmapInfo: CGBitmapInfo(
                              rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                                  | CGBitmapInfo.byteOrder32Little.rawValue
                          ).rawValue
                      ) else {
                    return nil
                }
                context.interpolationQuality = .none
                context.draw(
                    sourceImage,
                    in: CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight)
                )
                return context.makeImage()
            }) else {
                return nil
            }
            outputImage = image
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            "public.jpeg" as CFString,
            1,
            nil
        ) else {
            return nil
        }

        CGImageDestinationAddImage(destination, outputImage, [
            kCGImageDestinationLossyCompressionQuality: Double(quality) / 100.0,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
