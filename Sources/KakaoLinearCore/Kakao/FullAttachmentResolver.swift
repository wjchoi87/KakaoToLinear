import CryptoSwift
import Foundation

struct FullAttachmentResolver: Sendable {
  private static let maxFetchBytes: Int64 = 512 * 1024 * 1024
  let container: URL

  /*
   변경 전 정책 - attachment resolver가 존재하지 않아 full/thumbnail/CDN 구분 없이 파일 확보가 불가능했다.
   변경 후 정책 - local full cache를 먼저 검증하고, 없으면 checksum이 있는 full CDN만 사용하며 thumbnail은 절대 결과로 반환하지 않는다.
   변경 이유 - Linear에는 원본 또는 검증된 full-size 파일만 첨부하고 preview thumbnail 혼입을 막기 위해서다.
   영향 범위 - 사용자가 명시적으로 선택해 attachment get을 실행한 image, album frame, video, file에만 적용된다.
   */
  func resolve(
    attachment: KakaoAttachment,
    chatId: Int64,
    logId: Int64,
    messageType: Int64,
    frameIndex: Int,
    outputDirectory: URL
  ) async throws -> ResolvedAttachment {
    try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

    if attachment.kind != .file,
      let encryptedURL = findLocalFull(
        chatId: chatId,
        logId: logId,
        messageType: messageType,
        frameIndex: frameIndex
      )
    {
      let encrypted = try Data(contentsOf: encryptedURL)
      let plaintext = try decryptPkv2(encrypted, logId: logId)
      let sha1 = sha1Hex(plaintext)
      try validate(hash: sha1, expected: attachment.hash)
      let output = try outputURL(
        directory: outputDirectory,
        attachment: attachment,
        bytes: plaintext,
        fallbackStem: "\(logId)-\(frameIndex)"
      )
      try plaintext.write(to: output, options: .atomic)
      return ResolvedAttachment(
        attachment: attachment,
        fileURL: output,
        tier: .localFull,
        sha1: sha1
      )
    }

    guard let remoteURL = attachment.remoteURL else {
      throw KakaoLinearError.attachmentResolution("원본 attachment를 local cache와 CDN에서 찾지 못했습니다.")
    }
    guard attachment.hash?.isEmpty == false else {
      throw KakaoLinearError.attachmentResolution("checksum이 없는 CDN attachment는 저장하지 않습니다.")
    }
    if let byteSize = attachment.byteSize, byteSize > Self.maxFetchBytes {
      throw KakaoLinearError.attachmentResolution("attachment가 512MB 제한을 초과합니다.")
    }

    var request = URLRequest(url: remoteURL)
    request.timeoutInterval = 20
    request.setValue("KakaoTalk", forHTTPHeaderField: "User-Agent")
    let (bytes, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      throw KakaoLinearError.attachmentResolution("Kakao CDN에서 원본 attachment를 받지 못했습니다.")
    }
    guard Int64(bytes.count) <= Self.maxFetchBytes else {
      throw KakaoLinearError.attachmentResolution("다운로드된 attachment가 512MB 제한을 초과합니다.")
    }
    let sha1 = sha1Hex(bytes)
    try validate(hash: sha1, expected: attachment.hash)
    let output = try outputURL(
      directory: outputDirectory,
      attachment: attachment,
      bytes: bytes,
      fallbackStem: "\(logId)-\(frameIndex)"
    )
    try bytes.write(to: output, options: .atomic)
    return ResolvedAttachment(attachment: attachment, fileURL: output, tier: .cdn, sha1: sha1)
  }

  private func findLocalFull(
    chatId: Int64,
    logId: Int64,
    messageType: Int64,
    frameIndex: Int
  ) -> URL? {
    guard
      let entries = try? FileManager.default.contentsOfDirectory(
        at: container,
        includingPropertiesForKeys: [.isDirectoryKey]
      )
    else { return nil }
    let accountRoots = entries.filter { url in
      let name = url.lastPathComponent
      return name.count == 40
        && name.utf8.allSatisfy {
          (48...57).contains($0) || (97...102).contains($0)
        }
    }
    let roomDirectory = sha1Hex(Data(String(String(chatId).reversed()).utf8))
    let identity: String
    let fileExtension: String
    switch messageType {
    case 27:
      identity = "p\(frameIndex)_\(logId)"
      fileExtension = "img"
    case 3:
      identity = "v\(logId)"
      fileExtension = "vid"
    default:
      identity = "p\(logId)"
      fileExtension = "img"
    }
    let stem = sha1Hex(Data(String(identity.reversed()).utf8))
    return
      accountRoots
      .map { $0.appending(path: roomDirectory).appending(path: "\(stem).\(fileExtension)") }
      .first { FileManager.default.fileExists(atPath: $0.path) }
  }

  private func decryptPkv2(_ data: Data, logId: Int64) throws -> Data {
    let bytes = Array(data)
    guard bytes.count > 20, Array(bytes.prefix(4)) == Array("Pkv2".utf8) else {
      throw KakaoLinearError.attachmentResolution("local full cache가 Pkv2 형식이 아닙니다.")
    }
    let iv = Array(bytes[4..<20])
    let ciphertext = Array(bytes.dropFirst(20))
    guard ciphertext.count.isMultiple(of: AES.blockSize) else {
      throw KakaoLinearError.attachmentResolution("Pkv2 ciphertext block이 손상되었습니다.")
    }
    let keyString = String("#\(logId)%".reversed())
    let key = Array(keyString.utf8).sha256()
    let plaintext: [UInt8]
    do {
      plaintext = try AES(key: key, blockMode: CBC(iv: iv), padding: .pkcs7)
        .decrypt(ciphertext)
    } catch {
      throw KakaoLinearError.attachmentResolution("Pkv2 AES 복호화에 실패했습니다.")
    }
    guard plaintext.count >= 256 else {
      throw KakaoLinearError.attachmentResolution("Pkv2 wrapper가 손상되었습니다.")
    }
    return Data(plaintext.dropFirst(256))
  }

  private func validate(hash actual: String, expected: String?) throws {
    guard let expected, !expected.isEmpty else { return }
    guard actual.caseInsensitiveCompare(expected) == .orderedSame else {
      throw KakaoLinearError.attachmentResolution("attachment checksum 검증에 실패했습니다.")
    }
  }

  private func outputURL(
    directory: URL,
    attachment: KakaoAttachment,
    bytes: Data,
    fallbackStem: String
  ) throws -> URL {
    let fallbackExtension = sniffExtension(bytes, kind: attachment.kind)
    let proposed = attachment.originalName ?? "\(fallbackStem).\(fallbackExtension)"
    let safeName = sanitize(filename: proposed)
    let base = URL(fileURLWithPath: safeName).deletingPathExtension().lastPathComponent
    let ext = URL(fileURLWithPath: safeName).pathExtension
    var candidate = directory.appending(path: safeName)
    var suffix = 2
    while FileManager.default.fileExists(atPath: candidate.path) {
      let next = ext.isEmpty ? "\(base) (\(suffix))" : "\(base) (\(suffix)).\(ext)"
      candidate = directory.appending(path: next)
      suffix += 1
    }
    return candidate
  }

  private func sanitize(filename: String) -> String {
    let bidiScalarValues = Set<UInt32>([
      0x202A, 0x202B, 0x202C, 0x202D, 0x202E,
      0x2066, 0x2067, 0x2068, 0x2069,
    ])
    let lastComponent = URL(fileURLWithPath: filename).lastPathComponent
    let cleanedScalars = lastComponent.unicodeScalars.filter {
      !bidiScalarValues.contains($0.value)
        && $0.value >= 0x20
        && $0.value != 0x3A
        && $0.value != 0x2F
        && $0.value != 0x5C
    }
    let cleaned = String(String.UnicodeScalarView(cleanedScalars)).trimmingCharacters(
      in: .whitespacesAndNewlines)
    if cleaned.isEmpty || cleaned == "." || cleaned == ".." { return "attachment" }
    return String(cleaned.prefix(180))
  }

  private func sniffExtension(_ data: Data, kind: AttachmentKind) -> String {
    let bytes = Array(data.prefix(12))
    if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpg" }
    if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
    if bytes.starts(with: Array("GIF8".utf8)) { return "gif" }
    if bytes.starts(with: [0x52, 0x49, 0x46, 0x46]), bytes.count >= 12,
      Array(bytes[8..<12]) == Array("WEBP".utf8)
    {
      return "webp"
    }
    if bytes.starts(with: Array("%PDF".utf8)) { return "pdf" }
    return kind == .video ? "mp4" : "bin"
  }

  private func sha1Hex(_ data: Data) -> String {
    Array(data).sha1().toHexString()
  }
}
