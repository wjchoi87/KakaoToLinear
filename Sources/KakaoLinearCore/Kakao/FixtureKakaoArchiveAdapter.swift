import CryptoSwift
import Foundation

public final class FixtureKakaoArchiveAdapter: KakaoArchiveAdapter, @unchecked Sendable {
  private struct Fixture: Codable {
    let rooms: [KakaoRoom]
    let messages: [KakaoMessage]
  }

  private let fixture: Fixture

  public init(url: URL) throws {
    let data = try Data(contentsOf: url)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    do {
      fixture = try decoder.decode(Fixture.self, from: data)
    } catch {
      throw KakaoLinearError.invalidInput(
        "fixture JSON 형식이 올바르지 않습니다: \(error.localizedDescription)")
    }
  }

  public func listRooms(limit: Int, query: String?) throws -> [KakaoRoom] {
    guard limit > 0 else { throw KakaoLinearError.invalidInput("limit은 1 이상이어야 합니다.") }
    let rooms =
      query.map { needle in
        fixture.rooms.filter { $0.title.localizedCaseInsensitiveContains(needle) }
      } ?? fixture.rooms
    return rooms.sorted {
      ($0.lastActivityAt ?? .distantPast) > ($1.lastActivityAt ?? .distantPast)
    }.prefix(limit).map(\.self)
  }

  public func currentRoom() throws -> KakaoRoom? {
    fixture.rooms.max { ($0.lastActivityAt ?? .distantPast) < ($1.lastActivityAt ?? .distantPast) }
  }

  public func listMessages(
    roomId: String,
    beforeMessageId: String?,
    limit: Int
  ) throws -> [KakaoMessage] {
    guard fixture.rooms.contains(where: { $0.id == roomId }) else {
      throw KakaoLinearError.roomNotFound(roomId)
    }
    let before = try beforeMessageId.map(KakaoIdentifiers.logId)
    return fixture.messages
      .filter { message in
        guard message.roomId == roomId else { return false }
        guard let before else { return true }
        return ((try? KakaoIdentifiers.logId(from: message.id)) ?? .max) < before
      }
      .sorted { $0.timestamp < $1.timestamp }
      .suffix(limit)
      .map(\.self)
  }

  public func resolveAttachment(id: String, outputDirectory: URL) async throws -> ResolvedAttachment
  {
    guard let attachment = fixture.messages.flatMap(\.attachments).first(where: { $0.id == id }),
      let source = attachment.localFullPath
    else {
      throw KakaoLinearError.attachmentResolution("fixture full attachment를 찾지 못했습니다.")
    }
    try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    let destination = outputDirectory.appending(path: source.lastPathComponent)
    if FileManager.default.fileExists(atPath: destination.path) {
      throw KakaoLinearError.attachmentResolution(
        "출력 파일이 이미 존재합니다: \(destination.lastPathComponent)")
    }
    try FileManager.default.copyItem(at: source, to: destination)
    let sha1 = Array(try Data(contentsOf: destination)).sha1().toHexString()
    return ResolvedAttachment(
      attachment: attachment,
      fileURL: destination,
      tier: .localFull,
      sha1: sha1
    )
  }

  public func databaseIsReadable() -> Bool { true }
}
