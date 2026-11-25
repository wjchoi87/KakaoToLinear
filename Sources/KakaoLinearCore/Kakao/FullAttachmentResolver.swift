import CryptoSwift
import Foundation

struct FullAttachmentResolver: Sendable {
  private static let maxFetchBytes: Int64 = 512 * 1024 * 1024
  let container: URL
  private let session: URLSession

  init(container: URL, session: URLSession = .shared) {
    self.container = container
    self.session = session
  }

  /*
   변경 전 정책 - CDN fallback은 카톡 메타데이터에 checksum(cs/csl)이 있을 때만 받고, 없으면 종류와 무관하게 저장하지 않았다.
   변경 후 정책 - checksum이 없어도 image 첨부는 CDN에서 받는다. 대신 응답이 image 계열 Content-Type이거나 이미지 시그니처(jpg/png/gif/webp)일 때만
     저장한다. checksum이 있으면 기존처럼 SHA-1을 검증한다. file·video는 checksum이 없으면 기존처럼 저장하지 않는다.
     시그니처로 형식을 모르는 이미지는 응답 Content-Type subtype을 확장자로 쓴다.
   변경 이유 - 로컬 원본 캐시가 없는 이미지가 checksum 없음으로 계속 로드 실패했다(대장님 결정, 2026-11-25).
   영향 범위 - 로컬 full cache가 없어 CDN으로 가는 image/album frame. 미리보기·AI context·Linear 첨부에 그대로 쓰인다.
   */
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

    // 실패 메시지에 로컬/CDN 각각의 이유를 남겨 썸네일·로그에서 원인을 구분할 수 있게 한다.
    let localNote: String
    if attachment.kind == .file {
      localNote = "파일은 로컬 캐시 미사용"
    } else {
      switch findLocalFull(
        chatId: chatId,
        logId: logId,
        messageType: messageType,
        frameIndex: frameIndex
      ) {
      case .found(let encryptedURL):
        return try resolveLocal(
          encryptedURL: encryptedURL,
          attachment: attachment,
          logId: logId,
          frameIndex: frameIndex,
          outputDirectory: outputDirectory
        )
      case .missing(let reason):
        localNote = reason
      }
    }

    func failure(_ cdnNote: String) -> KakaoLinearError {
      .attachmentResolution("원본을 불러오지 못했습니다 — 로컬: \(localNote) · CDN: \(cdnNote)")
    }

    guard let remoteURL = attachment.remoteURL else {
      throw failure("주소 없음")
    }
    let expectedHash = attachment.hash?.isEmpty == false ? attachment.hash : nil
    guard expectedHash != nil || attachment.kind == .image else {
      throw failure("checksum 없음(저장하지 않음)")
    }
    if let byteSize = attachment.byteSize, byteSize > Self.maxFetchBytes {
      throw failure("512MB 제한 초과")
    }

    var request = URLRequest(url: remoteURL)
    request.timeoutInterval = 20
    request.setValue("KakaoTalk", forHTTPHeaderField: "User-Agent")
    let bytes: Data
    let response: URLResponse
    do {
      (bytes, response) = try await session.data(for: request)
    } catch {
      // 썸네일이 화면에서 사라져 task가 취소된 경우는 실패로 취급하지 않는다.
      if Task.isCancelled { throw CancellationError() }
      throw failure("요청 실패(\(error.localizedDescription))")
    }
    guard let http = response as? HTTPURLResponse else {
      throw failure("HTTP 응답 아님")
    }
    guard (200..<300).contains(http.statusCode) else {
      throw failure("HTTP \(http.statusCode)")
    }
    guard Int64(bytes.count) <= Self.maxFetchBytes else {
      throw failure("다운로드가 512MB 제한 초과")
    }
    let sha1 = sha1Hex(bytes)
    let contentType = http.value(forHTTPHeaderField: "Content-Type")
    if expectedHash != nil {
      do {
        try validate(hash: sha1, expected: expectedHash)
      } catch {
        throw failure("checksum 불일치")
      }
    } else if !isImagePayload(bytes, contentType: contentType) {
      throw failure("checksum 없음 · 이미지 형식 아님")
    }
    let output = try outputURL(
      directory: outputDirectory,
      attachment: attachment,
      bytes: bytes,
      fallbackStem: "\(logId)-\(frameIndex)",
      contentType: contentType
    )
    try bytes.write(to: output, options: .atomic)
    return ResolvedAttachment(attachment: attachment, fileURL: output, tier: .cdn, sha1: sha1)
  }

  private func resolveLocal(
    encryptedURL: URL,
    attachment: KakaoAttachment,
    logId: Int64,
    frameIndex: Int,
    outputDirectory: URL
  ) throws -> ResolvedAttachment {
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

  private enum LocalLookup {
    case found(URL)
    case missing(String)
  }

  private func findLocalFull(
    chatId: Int64,
    logId: Int64,
    messageType: Int64,
    frameIndex: Int
  ) -> LocalLookup {
    guard
      let entries = try? FileManager.default.contentsOfDirectory(
        at: container,
        includingPropertiesForKeys: [.isDirectoryKey]
      )
    else { return .missing("카카오톡 컨테이너 읽기 불가(권한 확인)") }
    let accountRoots = entries.filter { url in
      let name = url.lastPathComponent
      return name.count == 40
        && name.utf8.allSatisfy {
          (48...57).contains($0) || (97...102).contains($0)
        }
    }
    guard !accountRoots.isEmpty else { return .missing("계정 캐시 폴더 없음") }
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
    let roomRoots = accountRoots.map { $0.appending(path: roomDirectory) }
    guard roomRoots.contains(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
      return .missing("채팅방 캐시 폴더 없음")
    }
    if let found =
      roomRoots
      .map({ $0.appending(path: "\(stem).\(fileExtension)") })
      .first(where: { FileManager.default.fileExists(atPath: $0.path) })
    {
      return .found(found)
    }
    return .missing("원본 캐시 없음")
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

  /// checksum이 없을 때의 최소 검증. 만료 안내 HTML 같은 비이미지 응답을 이미지로 저장하지 않는다.
  private func isImagePayload(_ bytes: Data, contentType: String?) -> Bool {
    guard !bytes.isEmpty else { return false }
    if ["jpg", "png", "gif", "webp"].contains(sniffExtension(bytes, kind: .image)) { return true }
    return imageSubtype(contentType) != nil
  }

  /// `image/heic; ...` → `heic`. svg처럼 영숫자가 아닌 subtype은 쓰지 않는다.
  private func imageSubtype(_ contentType: String?) -> String? {
    guard
      let mime = contentType?.split(separator: ";").first?
        .trimmingCharacters(in: .whitespaces).lowercased(),
      mime.hasPrefix("image/")
    else { return nil }
    let subtype = mime.dropFirst("image/".count)
    guard (1...8).contains(subtype.count),
      subtype.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) && $0.isASCII })
    else { return nil }
    return String(subtype)
  }

  private func outputURL(
    directory: URL,
    attachment: KakaoAttachment,
    bytes: Data,
    fallbackStem: String,
    contentType: String? = nil
  ) throws -> URL {
    var fallbackExtension = sniffExtension(bytes, kind: attachment.kind)
    if fallbackExtension == "bin", attachment.kind == .image,
      let subtype = imageSubtype(contentType)
    {
      fallbackExtension = subtype
    }
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
