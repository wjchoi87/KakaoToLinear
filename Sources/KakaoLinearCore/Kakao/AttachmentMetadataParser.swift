import Foundation

struct AttachmentMetadataParser {
  func parse(logId: Int64, messageType: Int64, rawJSON: String?) -> [KakaoAttachment] {
    guard let rawJSON,
      let data = rawJSON.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return [] }

    switch messageType {
    case 2:
      return [single(logId: logId, kind: .image, object: object, index: 0)]
    case 3:
      return [single(logId: logId, kind: .video, object: object, index: 0)]
    case 18:
      return [single(logId: logId, kind: .file, object: object, index: 0)]
    case 27:
      let count = array(object["csl"]).count
      return (0..<count).map { album(logId: logId, object: object, index: $0) }
    default:
      return []
    }
  }

  private func single(
    logId: Int64,
    kind: AttachmentKind,
    object: [String: Any],
    index: Int
  ) -> KakaoAttachment {
    let remote = url(object["url"])
    let name = string(object["name"])
    return KakaoAttachment(
      id: KakaoIdentifiers.attachment(logId, index: index),
      messageId: KakaoIdentifiers.message(logId),
      kind: kind,
      originalName: name,
      mimeType: string(object["mt"]),
      byteSize: int64(object["size"]) ?? int64(object["s"]),
      remoteURL: remote,
      hash: string(object["cs"]),
      fullAvailable: remote != nil
    )
  }

  private func album(logId: Int64, object: [String: Any], index: Int) -> KakaoAttachment {
    let remote = url(value(in: object, key: "imageUrls", index: index))
    return KakaoAttachment(
      id: KakaoIdentifiers.attachment(logId, index: index),
      messageId: KakaoIdentifiers.message(logId),
      kind: .image,
      originalName: nil,
      mimeType: string(value(in: object, key: "mtl", index: index)),
      byteSize: int64(value(in: object, key: "sl", index: index)),
      remoteURL: remote,
      hash: string(value(in: object, key: "csl", index: index)),
      fullAvailable: remote != nil
    )
  }

  private func value(in object: [String: Any], key: String, index: Int) -> Any? {
    let values = array(object[key])
    return values.indices.contains(index) ? values[index] : nil
  }

  private func array(_ value: Any?) -> [Any] { value as? [Any] ?? [] }

  private func string(_ value: Any?) -> String? {
    if let string = value as? String, !string.isEmpty { return string }
    return nil
  }

  private func int64(_ value: Any?) -> Int64? {
    if let number = value as? NSNumber { return number.int64Value }
    if let string = value as? String { return Int64(string) }
    return nil
  }

  private func url(_ value: Any?) -> URL? {
    guard let string = string(value),
      let url = URL(string: string),
      url.scheme?.lowercased() == "https"
    else { return nil }
    return url
  }
}
