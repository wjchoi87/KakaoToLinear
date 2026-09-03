import Foundation

public struct IssueCreator: Sendable {
  private let client: LinearClient
  private let artifacts: ArtifactStore
  private let operations: OperationStore
  private let defaults: RoomDefaultsStore

  public init(
    client: LinearClient,
    artifacts: ArtifactStore,
    paths: AppSupportPaths = AppSupportPaths(),
    defaults: RoomDefaultsStore = RoomDefaultsStore()
  ) {
    self.client = client
    self.artifacts = artifacts
    operations = OperationStore(paths: paths)
    self.defaults = defaults
  }

  public func dryRun(draftId: String, options: LinearIssueOptions) async throws -> LinearDryRun {
    let draft = try await artifacts.loadDraft(draftId)
    let source = try await artifacts.loadSource(draft.sourceId)
    let description = LinearDescriptionBuilder().build(draft: draft, source: source)
    return LinearDryRun(
      draftId: draft.id,
      title: draft.title,
      description: description,
      options: options,
      attachmentNames: source.resolvedAttachments.map {
        $0.attachment.originalName ?? $0.fileURL.lastPathComponent
      }
    )
  }

  /*
   변경 전 정책 - Linear create 재시도 시 중복 이슈를 막는 상태가 없었다.
   변경 후 정책 - draft별 operation UUID를 Linear issue id로 사용하고 upload/result를 단계별 저장해 retry 시 복구한다.
   변경 이유 - network failure와 process 종료 뒤에도 동일 draft가 중복 issue를 만들지 않도록 하기 위해서다.
   영향 범위 - Linear issue create와 attachment upload 재시도, --force 동작에 적용된다.
   */
  public func create(
    draftId: String,
    options: LinearIssueOptions,
    force: Bool = false
  ) async throws -> LinearIssueResult {
    let draft = try await artifacts.loadDraft(draftId)
    let source = try await artifacts.loadSource(draft.sourceId)

    var operation: LinearOperation
    if !force, let existing = try await operations.existing(draftId: draftId) {
      if let result = existing.result {
        throw KakaoLinearError.alreadyCreated(
          "Issue already created: \(result.identifier) \(result.url.absoluteString)"
        )
      }
      operation = existing
    } else {
      operation = try await operations.create(draftId: draftId)
    }

    for attachment in source.resolvedAttachments
    where !operation.uploadedAssets.contains(where: { $0.attachmentId == attachment.attachment.id })
    {
      let asset = try await client.upload(attachment)
      operation.uploadedAssets.append(asset)
      try await operations.save(operation)
    }

    if let recovered = try await client.issue(id: operation.id) {
      operation.result = recovered
      try await operations.save(operation)
      try await defaults.set(RoomLinearDefaults(roomId: source.room.id, options: options))
      return recovered
    }

    let description = LinearDescriptionBuilder().build(
      draft: draft,
      source: source,
      assets: operation.uploadedAssets
    )
    let result = try await client.createIssue(
      id: operation.id,
      draft: draft,
      description: description,
      options: options
    )
    operation.result = result
    try await operations.save(operation)
    try await defaults.set(RoomLinearDefaults(roomId: source.room.id, options: options))
    return result
  }
}
