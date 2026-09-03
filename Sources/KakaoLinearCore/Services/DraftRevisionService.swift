import Foundation

public struct DraftRevisionService: Sendable {
  private let store: ArtifactStore

  public init(store: ArtifactStore) {
    self.store = store
  }

  public func persistManualEdits(_ current: IssueDraft) async throws -> IssueDraft {
    if let stored = try? await store.loadDraft(current.id), stored == current {
      return current
    }
    let reviewed = IssueDraft(
      id: "draft_\(UUID().uuidString.lowercased())",
      sourceId: current.sourceId,
      revision: current.revision + 1,
      parentDraftId: current.id,
      title: current.title,
      summary: current.summary,
      requirements: current.requirements,
      acceptanceCriteria: current.acceptanceCriteria,
      notes: current.notes,
      questions: current.questions,
      sourceMessageIds: current.sourceMessageIds
    )
    try await store.saveDraft(reviewed)
    return reviewed
  }
}
