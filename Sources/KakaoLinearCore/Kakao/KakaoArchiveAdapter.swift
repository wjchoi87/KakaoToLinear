import Foundation

public protocol KakaoArchiveAdapter: Sendable {
  func listRooms(limit: Int, query: String?) throws -> [KakaoRoom]
  func currentRoom() throws -> KakaoRoom?
  func listMessages(roomId: String, beforeMessageId: String?, limit: Int) throws -> [KakaoMessage]
  func resolveAttachment(id: String, outputDirectory: URL) async throws -> ResolvedAttachment
  func databaseIsReadable() -> Bool
}

extension KakaoArchiveAdapter {
  public func currentRoom() throws -> KakaoRoom? { nil }
}
