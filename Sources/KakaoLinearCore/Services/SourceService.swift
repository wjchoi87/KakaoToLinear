import Foundation

public struct SourceSelection: Sendable {
  public let roomId: String
  public let messageIds: [String]
  public let fromMessageId: String?
  public let toMessageId: String?

  public init(
    roomId: String,
    messageIds: [String] = [],
    fromMessageId: String? = nil,
    toMessageId: String? = nil
  ) {
    self.roomId = roomId
    self.messageIds = messageIds
    self.fromMessageId = fromMessageId
    self.toMessageId = toMessageId
  }
}

public struct SourceService: Sendable {
  private let adapter: any KakaoArchiveAdapter
  private let store: ArtifactStore

  public init(adapter: any KakaoArchiveAdapter, store: ArtifactStore) {
    self.adapter = adapter
    self.store = store
  }

  /*
   변경 전 정책 - message 선택 결과를 immutable source로 고정하는 기능이 없었다.
   변경 후 정책 - 선택된 message만 timestamp 순으로 고정하고 그 attachment만 resolve해 새 SourceBundle로 저장한다.
   변경 이유 - 선택하지 않은 대화가 AI로 전송되는 것을 막고 revision 동안 원문을 보존하기 위해서다.
   영향 범위 - CLI source create와 GUI의 정리 버튼으로 생성되는 모든 AI source에 적용된다.
   */
  public func create(selection: SourceSelection) async throws -> SourceBundle {
    guard
      !selection.messageIds.isEmpty
        || (selection.fromMessageId != nil && selection.toMessageId != nil)
    else {
      throw KakaoLinearError.invalidInput("message id 또는 from/to range가 필요합니다.")
    }
    guard
      selection.messageIds.isEmpty
        || (selection.fromMessageId == nil && selection.toMessageId == nil)
    else {
      throw KakaoLinearError.invalidInput("--message와 --from/--to는 동시에 사용할 수 없습니다.")
    }

    let rooms = try adapter.listRooms(limit: 1_000, query: nil)
    guard let room = rooms.first(where: { $0.id == selection.roomId }) else {
      throw KakaoLinearError.roomNotFound(selection.roomId)
    }
    let available = try loadUntilSelectionIsAvailable(selection)
    let selected = try selectedMessages(selection: selection, available: available)
    guard !selected.isEmpty else {
      throw KakaoLinearError.invalidInput("선택된 message가 없습니다.")
    }

    let sourceId = "src_\(UUID().uuidString.lowercased())"
    let output = try await store.attachmentOutputDirectory(sourceId: sourceId)
    var resolved: [ResolvedAttachment] = []
    var failures: [AttachmentFailure] = []
    for attachment in selected.flatMap(\.attachments) {
      do {
        resolved.append(
          try await adapter.resolveAttachment(id: attachment.id, outputDirectory: output)
        )
      } catch {
        failures.append(
          AttachmentFailure(
            attachmentId: attachment.id,
            reason: (error as? LocalizedError)?.errorDescription ?? "원본 확보 실패"
          ))
      }
    }

    let source = SourceBundle(
      id: sourceId,
      room: room,
      messages: selected.sorted { $0.timestamp < $1.timestamp },
      resolvedAttachments: resolved,
      attachmentFailures: failures
    )
    try await store.saveSource(source)
    return source
  }

  private func loadUntilSelectionIsAvailable(_ selection: SourceSelection) throws -> [KakaoMessage]
  {
    let targetIds = Set(
      selection.messageIds + [selection.fromMessageId, selection.toMessageId].compactMap(\.self)
    )
    var available: [KakaoMessage] = []
    var before: String?
    for _ in 0..<100 {
      let batch = try adapter.listMessages(
        roomId: selection.roomId,
        beforeMessageId: before,
        limit: 1_000
      )
      guard !batch.isEmpty else { break }
      available = batch + available
      if targetIds.isSubset(of: Set(available.map(\.id))) { break }
      guard let oldest = batch.first?.id, oldest != before else { break }
      before = oldest
    }
    return available
  }

  private func selectedMessages(
    selection: SourceSelection,
    available: [KakaoMessage]
  ) throws -> [KakaoMessage] {
    if !selection.messageIds.isEmpty {
      let ids = Set(selection.messageIds)
      let selected = available.filter { ids.contains($0.id) }
      let missing = ids.subtracting(selected.map(\.id))
      guard missing.isEmpty else {
        throw KakaoLinearError.messageNotFound(missing.sorted().joined(separator: ", "))
      }
      return selected
    }

    guard let from = selection.fromMessageId,
      let to = selection.toMessageId,
      let fromIndex = available.firstIndex(where: { $0.id == from }),
      let toIndex = available.firstIndex(where: { $0.id == to })
    else {
      throw KakaoLinearError.messageNotFound("range endpoint")
    }
    let lower = min(fromIndex, toIndex)
    let upper = max(fromIndex, toIndex)
    return Array(available[lower...upper])
  }
}
