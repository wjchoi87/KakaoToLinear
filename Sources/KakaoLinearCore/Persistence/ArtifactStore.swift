import CryptoKit
import Foundation

public actor ArtifactStore {
  private let paths: AppSupportPaths
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder

  public init(paths: AppSupportPaths = AppSupportPaths()) {
    self.paths = paths
    encoder = JSONEncoder.kakaoLinear
    decoder = JSONDecoder.kakaoLinear
  }

  // MARK: - Source hash (cache 재사용 판정용)

  /// SourceBundle의 immutable 내용(room/messages/attachment id)에 대한 안정 hash.
  /// createdAt 등 non-deterministic 필드는 제외해 같은 source는 항상 같은 hash가 나오게 한다.
  public func sourceHash(_ source: SourceBundle) throws -> String {
    let ids = source.messages.map(\.id).joined(separator: "|")
    let attIds = source.resolvedAttachments.map(\.attachment.id).joined(separator: "|")
    let lines = [
      source.room.id,
      ids,
      attIds,
      source.attachmentFailures.map(\.attachmentId).joined(separator: "|"),
    ]
    let data = Data(lines.joined(separator: "\u{1E}").utf8)
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  // MARK: - Evidence

  public func saveEvidence(_ analysis: EvidenceAnalysis) throws {
    try paths.ensureDirectories()
    let url = evidenceURL(analysis.id)
    guard !FileManager.default.fileExists(atPath: url.path) else { return }
    try write(analysis, to: url)
  }

  public func loadEvidence(_ id: String) throws -> EvidenceAnalysis {
    try read(EvidenceAnalysis.self, from: evidenceURL(id), label: "evidence")
  }

  /// source hash가 일치하는 최신 cached evidence를 반환한다. 없으면 nil.
  public func latestEvidence(sourceId: String, sourceHash: String) throws -> EvidenceAnalysis? {
    let files = try FileManager.default.contentsOfDirectory(
      at: paths.evidence,
      includingPropertiesForKeys: nil
    )
    return files.compactMap { try? read(EvidenceAnalysis.self, from: $0, label: "evidence") }
      .filter { $0.sourceId == sourceId && $0.sourceHash == sourceHash }
      .sorted { $0.createdAt > $1.createdAt }
      .first
  }

  public func listEvidence(sourceId: String) throws -> [EvidenceAnalysis] {
    try paths.ensureDirectories()
    let files = try FileManager.default.contentsOfDirectory(
      at: paths.evidence,
      includingPropertiesForKeys: nil
    )
    return files.compactMap { try? read(EvidenceAnalysis.self, from: $0, label: "evidence") }
      .filter { $0.sourceId == sourceId }
      .sorted { $0.createdAt > $1.createdAt }
  }

  /*
   변경 전 정책 - source와 draft를 영속화하는 저장 계층이 없었다.
   변경 후 정책 - source는 최초 1회만 저장하고 덮어쓰지 않으며, revision은 항상 새 draft id로 저장한다.
   변경 이유 - 재정리 과정에서도 원문을 immutable truth source로 유지하기 위해서다.
   영향 범위 - source create, compose, revise, Linear create가 읽고 쓰는 local artifact 전체에 적용된다.
   */
  public func saveSource(_ source: SourceBundle) throws {
    try paths.ensureDirectories()
    let url = sourceURL(source.id)
    guard !FileManager.default.fileExists(atPath: url.path) else {
      throw KakaoLinearError.invalidInput("이미 존재하는 source id입니다: \(source.id)")
    }
    try write(source, to: url)
  }

  public func loadSource(_ id: String) throws -> SourceBundle {
    try read(SourceBundle.self, from: sourceURL(id), label: "source")
  }

  public func saveDraft(_ draft: IssueDraft) throws {
    try paths.ensureDirectories()
    let url = draftURL(draft.id)
    guard !FileManager.default.fileExists(atPath: url.path) else {
      throw KakaoLinearError.invalidInput("이미 존재하는 draft id입니다: \(draft.id)")
    }
    try write(draft, to: url)
  }

  public func loadDraft(_ id: String) throws -> IssueDraft {
    try read(IssueDraft.self, from: draftURL(id), label: "draft")
  }

  public func listDrafts(sourceId: String) throws -> [IssueDraft] {
    try paths.ensureDirectories()
    let files = try FileManager.default.contentsOfDirectory(
      at: paths.drafts,
      includingPropertiesForKeys: nil
    )
    return files.compactMap { try? read(IssueDraft.self, from: $0, label: "draft") }
      .filter { $0.sourceId == sourceId }
      .sorted { $0.revision < $1.revision }
  }

  public func attachmentOutputDirectory(sourceId: String) throws -> URL {
    try paths.ensureDirectories()
    let directory = paths.resolvedAttachments.appending(path: safeIdentifier(sourceId))
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  private func sourceURL(_ id: String) -> URL {
    paths.sources.appending(path: "\(safeIdentifier(id)).json")
  }

  private func draftURL(_ id: String) -> URL {
    paths.drafts.appending(path: "\(safeIdentifier(id)).json")
  }

  private func evidenceURL(_ id: String) -> URL {
    paths.evidence.appending(path: "\(safeIdentifier(id)).json")
  }

  private func safeIdentifier(_ id: String) -> String {
    id.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
  }

  private func read<Value: Decodable>(_ type: Value.Type, from url: URL, label: String) throws
    -> Value
  {
    do {
      return try decoder.decode(type, from: Data(contentsOf: url))
    } catch {
      throw KakaoLinearError.invalidInput("\(label)을 읽을 수 없습니다: \(url.lastPathComponent)")
    }
  }

  private func write<Value: Encodable>(_ value: Value, to url: URL) throws {
    let data = try encoder.encode(value)
    try data.write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }
}

extension JSONEncoder {
  public static var kakaoLinear: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .custom { date, encoder in
      var container = encoder.singleValueContainer()
      let formatter = ISO8601DateFormatter()
      formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      try container.encode(formatter.string(from: date))
    }
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return encoder
  }
}

extension JSONDecoder {
  public static var kakaoLinear: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom { decoder in
      let container = try decoder.singleValueContainer()
      let value = try container.decode(String.self)
      let fractional = ISO8601DateFormatter()
      fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      if let date = fractional.date(from: value) { return date }
      let standard = ISO8601DateFormatter()
      guard let date = standard.date(from: value) else {
        throw DecodingError.dataCorruptedError(
          in: container,
          debugDescription: "Invalid ISO8601 date"
        )
      }
      return date
    }
    return decoder
  }
}
