import Foundation

public struct IssueComposer: Sendable {
  private let provider: any AIProvider
  private let store: ArtifactStore

  public init(provider: any AIProvider, store: ArtifactStore) {
    self.provider = provider
    self.store = store
  }

  /// PASS 1 evidence를 반환한다. source가 바뀌지 않았으면 cache를 재사용한다.
  /// forceRefresh가 true이면 항상 재분석하고 cache를 갱신한다.
  public func analyze(
    sourceId: String,
    agentsInstructions: String? = nil,
    forceRefresh: Bool = false
  ) async throws -> EvidenceAnalysis {
    let source = try await store.loadSource(sourceId)
    let hash = try await store.sourceHash(source)
    if !forceRefresh,
      let cached = try await store.latestEvidence(sourceId: sourceId, sourceHash: hash)
    {
      return cached
    }
    var analysis = try await provider.analyzeEvidence(
      source: source, agentsInstructions: agentsInstructions)
    analysis = self.stampingHash(analysis, hash: hash)
    // semantic validation + 최대 1회 repair
    analysis = try await validateAndRepairEvidence(analysis, source: source)
    analysis = self.stampingHash(analysis, hash: hash)
    try await store.saveEvidence(analysis)
    return analysis
  }

  private func stampingHash(_ analysis: EvidenceAnalysis, hash: String) -> EvidenceAnalysis {
    // provider가 source hash를 모르는 경우가 있어 저장/조회 일관성을 위해 실제 hash로 덮어쓴다.
    EvidenceAnalysis(
      id: analysis.id,
      sourceId: analysis.sourceId,
      sourceHash: hash,
      facts: analysis.facts,
      requests: analysis.requests,
      constraints: analysis.constraints,
      conditions: analysis.conditions,
      exclusions: analysis.exclusions,
      ambiguities: analysis.ambiguities,
      relationships: analysis.relationships,
      attachmentInsights: analysis.attachmentInsights,
      overallConfidence: analysis.overallConfidence,
      createdAt: analysis.createdAt
    )
  }

  public func compose(
    sourceId: String,
    agentsInstructions: String? = nil,
    evidence: EvidenceAnalysis? = nil
  ) async throws -> IssueDraft {
    let analysis: EvidenceAnalysis
    if let evidence {
      analysis = evidence
    } else {
      analysis = try await analyze(sourceId: sourceId, agentsInstructions: agentsInstructions)
    }
    let source = try await store.loadSource(sourceId)
    let draft = try await provider.composeIssue(
      source: source, evidence: analysis, agentsInstructions: agentsInstructions)
    try await store.saveDraft(draft)
    return draft
  }

  public func revise(
    draftId: String,
    instruction: String,
    agentsInstructions: String? = nil,
    evidence: EvidenceAnalysis? = nil
  ) async throws -> IssueDraft {
    let current = try await store.loadDraft(draftId)
    let source = try await store.loadSource(current.sourceId)
    let analysis: EvidenceAnalysis
    if let evidence {
      analysis = evidence
    } else {
      // revision 시 PASS 1은 재사용. source가 안 바뀌었으면 cache, 아니면 재분석.
      analysis = try await analyze(
        sourceId: source.id, agentsInstructions: agentsInstructions)
    }
    let draft = try await provider.reviseIssue(
      source: source,
      evidence: analysis,
      current: current,
      instruction: instruction,
      agentsInstructions: agentsInstructions
    )
    try await store.saveDraft(draft)
    return draft
  }

  // MARK: - Semantic validation (무한 retry 금지, 최대 1회 repair)

  private func validateAndRepairEvidence(
    _ analysis: EvidenceAnalysis,
    source: SourceBundle
  ) async throws -> EvidenceAnalysis {
    let validMessageIds = Set(source.messages.map(\.id))
    let validAttachmentIds = Set(source.resolvedAttachments.map(\.attachment.id))

    func clampConfidence(_ value: Double) -> Double { min(max(value, 0), 1) }
    func clean(_ item: EvidenceItem) -> EvidenceItem {
      EvidenceItem(
        id: item.id,
        source: item.source,
        content: item.content.trimmingCharacters(in: .whitespacesAndNewlines),
        sourceMessageIds: item.sourceMessageIds.filter { validMessageIds.contains($0) },
        attachmentIds: item.attachmentIds.filter { validAttachmentIds.contains($0) },
        confidence: clampConfidence(item.confidence),
        kind: item.kind,
        name: item.name
      )
    }

    let hasContent = !analysis.allItems.filter { !$0.content.isEmpty }.isEmpty
    let hasRequest = !analysis.requests.isEmpty
    let ambiguous = analysis.ambiguities.filter { !$0.content.isEmpty }
    var repaired = EvidenceAnalysis(
      id: analysis.id,
      sourceId: analysis.sourceId,
      sourceHash: analysis.sourceHash,
      facts: analysis.facts.map(clean).filter { !$0.content.isEmpty },
      requests: analysis.requests.map(clean).filter { !$0.content.isEmpty },
      constraints: analysis.constraints.map(clean).filter { !$0.content.isEmpty },
      conditions: analysis.conditions.map(clean).filter { !$0.content.isEmpty },
      exclusions: analysis.exclusions.map(clean).filter { !$0.content.isEmpty },
      ambiguities: ambiguous.map(clean),
      relationships: analysis.relationships.map(clean).filter { !$0.content.isEmpty },
      attachmentInsights: analysis.attachmentInsights,
      overallConfidence: analysis.overallConfidence.map(clampConfidence),
      createdAt: analysis.createdAt
    )

    // 요구사항이 하나도 없거나 모든 evidence가 비어 있으면 1회 재분석 시도.
    if !hasRequest || !hasContent {
      let source = try await store.loadSource(analysis.sourceId)
      let retried = try await provider.analyzeEvidence(
        source: source, agentsInstructions: nil)
      repaired = EvidenceAnalysis(
        id: analysis.id,
        sourceId: analysis.sourceId,
        sourceHash: analysis.sourceHash,
        facts: retried.facts.map(clean),
        requests: retried.requests.map(clean),
        constraints: retried.constraints.map(clean),
        conditions: retried.conditions.map(clean),
        exclusions: retried.exclusions.map(clean),
        ambiguities: retried.ambiguities.map(clean),
        relationships: retried.relationships.map(clean),
        attachmentInsights: retried.attachmentInsights,
        overallConfidence: retried.overallConfidence.map(clampConfidence),
        createdAt: analysis.createdAt
      )
    }
    return repaired
  }
}
