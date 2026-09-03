import Foundation
import ImageIO
import UniformTypeIdentifiers

struct AIImageOptimizer: Sendable {
  let maximumLongEdge: Int = 2048

  func jpegData(from url: URL) throws -> Data {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
      throw KakaoLinearError.aiProvider("AI용 image를 열 수 없습니다: \(url.lastPathComponent)")
    }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceThumbnailMaxPixelSize: maximumLongEdge,
      kCGImageSourceCreateThumbnailWithTransform: true,
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
      throw KakaoLinearError.aiProvider("AI용 image thumbnail 생성에 실패했습니다.")
    }
    let data = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        data,
        UTType.jpeg.identifier as CFString,
        1,
        nil
      )
    else {
      throw KakaoLinearError.aiProvider("AI용 JPEG encoder를 만들 수 없습니다.")
    }
    CGImageDestinationAddImage(
      destination,
      image,
      [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary
    )
    guard CGImageDestinationFinalize(destination) else {
      throw KakaoLinearError.aiProvider("AI용 JPEG 생성에 실패했습니다.")
    }
    return data as Data
  }
}
