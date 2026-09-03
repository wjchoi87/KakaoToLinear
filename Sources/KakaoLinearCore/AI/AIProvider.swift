import Foundation

public protocol AIProvider: Sendable {
  // PASS 1 — evidence extraction만 수행, 최종 이슈 문장을 만들지 않는다.
  func analyzeEvidence(
    source: SourceBundle,
    agentsInstructions: String?
  ) async throws -> EvidenceAnalysis

  // PASS 2 — 원본 SourceBundle + EvidenceAnalysis를 함께 참조해 최종 이슈를 합성한다.
  func composeIssue(
    source: SourceBundle,
    evidence: EvidenceAnalysis,
    agentsInstructions: String?
  ) async throws -> IssueDraft

  func reviseIssue(
    source: SourceBundle,
    evidence: EvidenceAnalysis,
    current: IssueDraft,
    instruction: String,
    agentsInstructions: String?
  ) async throws -> IssueDraft

  func healthCheck() async -> Bool
}
