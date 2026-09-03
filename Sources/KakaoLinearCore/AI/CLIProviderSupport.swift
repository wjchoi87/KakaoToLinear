import Foundation

struct CLIDraftPayload: Codable, Sendable {
  let title: String
  let summary: String
  let requirements: [String]
  let acceptanceCriteria: [String]
  let notes: [String]
  let questions: [String]
  let sourceMessageIds: [String]
}

/// PASS 1 evidence payload. provider가 반환해야 하는 JSON 구조와 1:1 대응한다.
/// 모델이 필드를 일부 빠뜨리는 것을 허용하도록 optional로 관대하게 디코딩한다.
struct CLEvidencePayload: Codable, Sendable {
  struct Item: Codable, Sendable {
    let content: String
    let sourceMessageIds: [String]
    let attachmentIds: [String]
    let confidence: Double
    let kind: String?

    init(
      content: String,
      sourceMessageIds: [String],
      attachmentIds: [String],
      confidence: Double,
      kind: String?
    ) {
      self.content = content
      self.sourceMessageIds = sourceMessageIds
      self.attachmentIds = attachmentIds
      self.confidence = confidence
      self.kind = kind
    }

    private enum CodingKeys: String, CodingKey {
      case content, sourceMessageIds, attachmentIds, confidence, kind
      case description  // 모델이 content 대신 description을 쓰는 경우 허용
    }

    init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      // content가 없으면 description 키를 fallback으로 사용한다.
      content =
        (try c.decodeIfPresent(String.self, forKey: .content)
        ?? c.decodeIfPresent(String.self, forKey: .description)
        ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      sourceMessageIds = (try c.decodeIfPresent([String].self, forKey: .sourceMessageIds)) ?? []
      attachmentIds = (try c.decodeIfPresent([String].self, forKey: .attachmentIds)) ?? []
      confidence = (try? c.decodeIfPresent(Double.self, forKey: .confidence)) ?? 1.0
      kind = try c.decodeIfPresent(String.self, forKey: .kind)
    }

    func encode(to encoder: Encoder) throws {
      var c = encoder.container(keyedBy: CodingKeys.self)
      try c.encode(content, forKey: .content)
      try c.encode(sourceMessageIds, forKey: .sourceMessageIds)
      try c.encode(attachmentIds, forKey: .attachmentIds)
      try c.encode(confidence, forKey: .confidence)
      try c.encodeIfPresent(kind, forKey: .kind)
    }
  }
  struct Insight: Codable, Sendable {
    let attachmentId: String
    let type: String
    let observations: [String]
    let relatedMessageIds: [String]
    let relatedRequests: [String]
    let ambiguities: [String]
    let confidence: Double

    private enum CodingKeys: String, CodingKey {
      case attachmentId, type, observations, relatedMessageIds, relatedRequests, ambiguities,
        confidence
    }

    init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      attachmentId = (try c.decodeIfPresent(String.self, forKey: .attachmentId)) ?? ""
      type = (try c.decodeIfPresent(String.self, forKey: .type)) ?? "other"
      observations = (try c.decodeIfPresent([String].self, forKey: .observations)) ?? []
      relatedMessageIds =
        (try c.decodeIfPresent([String].self, forKey: .relatedMessageIds)) ?? []
      relatedRequests =
        (try c.decodeIfPresent([String].self, forKey: .relatedRequests)) ?? []
      ambiguities = (try c.decodeIfPresent([String].self, forKey: .ambiguities)) ?? []
      confidence = (try? c.decodeIfPresent(Double.self, forKey: .confidence)) ?? 1.0
    }

    func encode(to encoder: Encoder) throws {
      var c = encoder.container(keyedBy: CodingKeys.self)
      try c.encode(attachmentId, forKey: .attachmentId)
      try c.encode(type, forKey: .type)
      try c.encode(observations, forKey: .observations)
      try c.encode(relatedMessageIds, forKey: .relatedMessageIds)
      try c.encode(relatedRequests, forKey: .relatedRequests)
      try c.encode(ambiguities, forKey: .ambiguities)
      try c.encode(confidence, forKey: .confidence)
    }
  }
  let facts: [Item]
  let requests: [Item]
  let constraints: [Item]
  let conditions: [Item]
  let exclusions: [Item]
  let ambiguities: [Item]
  let relationships: [Item]
  let attachmentInsights: [Insight]
  let overallConfidence: Double?
}

struct CLIProviderSupport: Sendable {
  static let policy = """
    Convert explicitly selected KakaoTalk messages into a software work issue.
    Use only supplied source messages and attachment-derived context.
    Never invent requirements or implementation details.
    Preserve explicit exclusions and scope.
    Separate requirements, acceptance criteria, notes, and questions.
    Do not infer Linear metadata such as project, status, assignee, labels, or priority.
    Preserve traceability to supplied message IDs.
    Revision instructions can change interpretation, but the original source remains authoritative.
    Do not call tools, inspect the workspace, or access unrelated files.
    Return only the JSON object required by the supplied schema.
    """

  // PASS 1 정책: 정보 손실을 막고, 최종 이슈 문장을 만들지 않는다.
  static let evidencePolicy = """
    You are a Senior Requirements Analyst, QA Analyst, and UI/UX Evidence Analyst.
    Your ONLY job is to exhaustively extract evidence from the supplied KakaoTalk source
    without writing any final issue sentences.

    Rules:
    1. Never compress, merge, invent, or finalize requirements.
    2. Do not propose implementation details (APIs, DB, CSS, components, architecture).
    3. Explicitly stated content → facts / requests / scope(constraints) / exclusions / conditions.
    4. Uncertain content → ambiguities, never facts.
    5. Connect messages into a conversation: questions, answers, revisions that override earlier messages.
       "PC는 그대로", "모바일만" 같은 scope/exclusion must appear verbatim as constraints/exclusions.
    6. For each attached image (vision input): describe the screen, important UI elements,
       annotations (red box/arrow/circle/underline), embedded text, error messages, button/field/layout
       position, current UI state, and how it answers or complements message text like "여기 / 이 부분 / 이 버튼".
       Never reduce an image to a one-line caption.
    7. Conflicting image vs text must be kept as ambiguities, not resolved arbitrarily.
    8. Every evidence item should reference sourceMessageIds, and attachmentIds when it came from an attachment.
    9. Fill attachmentInsights so the user can verify each attachment was understood.
    10. Respond with JSON only using the supplied schema keys.
    """

  // PASS 2 정책: 원문 + evidence를 함께 보고 실제 작업 가능한 이슈를 작성한다.
  static let synthesisPolicy = """
    You are a Senior Product / Requirements Analyst.
    Produce a Linear issue a developer can actually work from.
    You receive BOTH the original source and PASS 1 evidence analysis. Re-read the original when needed.

    Policy:
    1. Explicit content → requirements / scope / constraints.
    2. High-probability interpretation → notes, never requirements.
    3. Cannot confirm → questions, never requirements.
    4. Do not invent acceptance criteria that are not in the source.
    5. Preserve exclusions exactly (e.g. "PC is unchanged").
    6. The issue must answer: what to change, current problem, desired behavior, platform/screen/condition scope,
       what must NOT change, what each attachment shows, acceptance basis, and open questions.
    7. Attach provenance: sourceMessageIds per requirement where possible.
    8. Respond with JSON only using the supplied schema keys.
    """

  /// evidence가 있는 compose에 사용할 PASS 2 prompt.
  func synthesisPrompt(
    source: SourceBundle,
    evidence: EvidenceAnalysis,
    current: IssueDraft?,
    instruction: String?,
    agentsInstructions: String?
  ) throws -> String {
    var sections = [Self.synthesisPolicy]
    let trimmed = agentsInstructions?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !trimmed.isEmpty {
      sections.append("PRECEDING GUIDELINES (AGENTS.md):\n\(trimmed)")
    }
    sections.append("ORIGINAL SOURCE (authoritative):")
    sections.append(SourcePromptFormatter().format(source))
    sections.append(try TextAttachmentExtractor().context(from: source.resolvedAttachments))
    sections.append("PASS 1 EVIDENCE ANALYSIS:")
    sections.append(String(decoding: try JSONEncoder.kakaoLinear.encode(evidence), as: UTF8.self))
    if let current {
      let data = try JSONEncoder.kakaoLinear.encode(current)
      sections.append("CURRENT DRAFT:\n\(String(decoding: data, as: UTF8.self))")
    }
    if let instruction { sections.append("USER REVISION INSTRUCTION:\n\(instruction)") }
    return sections.joined(separator: "\n\n")
  }

  /// PASS 1 evidence 전용 prompt.
  func evidencePrompt(
    source: SourceBundle,
    agentsInstructions: String?
  ) -> String {
    var sections = [Self.evidencePolicy]
    let trimmed = agentsInstructions?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !trimmed.isEmpty {
      sections.append("PRECEDING GUIDELINES (AGENTS.md):\n\(trimmed)")
    }
    sections.append(SourcePromptFormatter().format(source))
    sections.append(
      (try? TextAttachmentExtractor().context(from: source.resolvedAttachments)) ?? "")
    sections.append(
      "Analyze every message, every image you receive, and every extracted document. "
        + "Be exhaustive. Do not write a final issue.")
    return sections.joined(separator: "\n\n")
  }

  func draftSchemaData() throws -> Data {
    let stringArray: [String: Any] = ["type": "array", "items": ["type": "string"]]
    let schema: [String: Any] = [
      "type": "object",
      "additionalProperties": false,
      "required": [
        "title", "summary", "requirements", "acceptanceCriteria", "notes", "questions",
        "sourceMessageIds",
      ],
      "properties": [
        "title": ["type": "string"],
        "summary": ["type": "string"],
        "requirements": stringArray,
        "acceptanceCriteria": stringArray,
        "notes": stringArray,
        "questions": stringArray,
        "sourceMessageIds": stringArray,
      ],
    ]
    return try JSONSerialization.data(
      withJSONObject: schema, options: [.prettyPrinted, .sortedKeys])
  }

  func evidenceSchemaData() throws -> Data {
    let item: [String: Any] = [
      "type": "object",
      "additionalProperties": false,
      "required": ["content", "sourceMessageIds", "attachmentIds", "confidence"],
      "properties": [
        "content": ["type": "string"],
        "sourceMessageIds": ["type": "array", "items": ["type": "string"]],
        "attachmentIds": ["type": "array", "items": ["type": "string"]],
        "confidence": ["type": "number", "minimum": 0, "maximum": 1],
        "kind": ["type": "string"],
      ],
    ]
    let itemArray: [String: Any] = ["type": "array", "items": item]
    let insight: [String: Any] = [
      "type": "object",
      "additionalProperties": false,
      "required": ["attachmentId", "type", "observations"],
      "properties": [
        "attachmentId": ["type": "string"],
        "type": ["type": "string", "enum": ["image", "document", "other"]],
        "observations": ["type": "array", "items": ["type": "string"]],
        "relatedMessageIds": ["type": "array", "items": ["type": "string"]],
        "relatedRequests": ["type": "array", "items": ["type": "string"]],
        "ambiguities": ["type": "array", "items": ["type": "string"]],
        "confidence": ["type": "number", "minimum": 0, "maximum": 1],
      ],
    ]
    let schema: [String: Any] = [
      "type": "object",
      "additionalProperties": false,
      "required": [
        "facts", "requests", "constraints", "conditions", "exclusions", "ambiguities",
        "relationships", "attachmentInsights",
      ],
      "properties": [
        "facts": itemArray,
        "requests": itemArray,
        "constraints": itemArray,
        "conditions": itemArray,
        "exclusions": itemArray,
        "ambiguities": itemArray,
        "relationships": itemArray,
        "attachmentInsights": ["type": "array", "items": insight],
        "overallConfidence": ["type": "number", "minimum": 0, "maximum": 1],
      ],
    ]
    return try JSONSerialization.data(
      withJSONObject: schema, options: [.prettyPrinted, .sortedKeys])
  }

  func decodePayload(_ data: Data) throws -> CLIDraftPayload {
    var text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    if text.hasPrefix("```") {
      text = text.replacingOccurrences(of: "```json", with: "")
        .replacingOccurrences(of: "```", with: "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard let normalized = text.data(using: .utf8) else {
      throw KakaoLinearError.aiProvider("AI CLI output을 UTF-8 JSON으로 변환하지 못했습니다.")
    }
    do {
      let payload = try JSONDecoder().decode(CLIDraftPayload.self, from: normalized)
      guard !payload.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw KakaoLinearError.aiProvider("AI CLI draft title이 비어 있습니다.")
      }
      return payload
    } catch let error as KakaoLinearError {
      throw error
    } catch {
      AIErrorLogger().logDecodeFailure(rawResponse: text, error: error)
      throw KakaoLinearError.aiProvider("AI CLI가 structured draft JSON을 반환하지 않았습니다.")
    }
  }

  func decodeEvidencePayload(_ data: Data) throws -> CLEvidencePayload {
    var text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    if text.hasPrefix("```") {
      text = text.replacingOccurrences(of: "```json", with: "")
        .replacingOccurrences(of: "```", with: "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard let normalized = text.data(using: .utf8) else {
      throw KakaoLinearError.aiProvider("AI CLI evidence output을 UTF-8 JSON으로 변환하지 못했습니다.")
    }
    do {
      return try JSONDecoder().decode(CLEvidencePayload.self, from: normalized)
    } catch {
      throw KakaoLinearError.aiProvider("AI CLI가 structured evidence JSON을 반환하지 않았습니다.")
    }
  }

  func makeDraft(
    payload: CLIDraftPayload,
    source: SourceBundle,
    current: IssueDraft?
  ) -> IssueDraft {
    let validIds = Set(source.messages.map(\.id))
    let traced = payload.sourceMessageIds.filter(validIds.contains)
    return IssueDraft(
      id: "draft_\(UUID().uuidString.lowercased())",
      sourceId: source.id,
      revision: (current?.revision ?? 0) + 1,
      parentDraftId: current?.id,
      title: payload.title,
      summary: payload.summary,
      requirements: payload.requirements,
      acceptanceCriteria: payload.acceptanceCriteria,
      notes: payload.notes,
      questions: payload.questions,
      sourceMessageIds: traced.isEmpty ? source.messages.map(\.id) : traced
    )
  }

  func makeEvidence(
    payload: CLEvidencePayload,
    source: SourceBundle,
    sourceHash: String
  ) -> EvidenceAnalysis {
    let validMessageIds = Set(source.messages.map(\.id))
    let validAttachmentIds = Set(source.resolvedAttachments.map(\.attachment.id))
    func toItems(_ items: [CLEvidencePayload.Item], source: EvidenceSource) -> [EvidenceItem] {
      items.enumerated().map { index, item in
        EvidenceItem(
          id: "ev_\(source.rawValue)_\(index)",
          source: source,
          content: item.content.trimmingCharacters(in: .whitespacesAndNewlines),
          sourceMessageIds: item.sourceMessageIds.filter(validMessageIds.contains),
          attachmentIds: item.attachmentIds.filter(validAttachmentIds.contains),
          confidence: min(max(item.confidence, 0), 1),
          kind: item.kind
        )
      }
    }
    let insights = payload.attachmentInsights.map { insight in
      AttachmentInsight(
        attachmentId: insight.attachmentId,
        type: insight.type,
        observations: insight.observations,
        relatedMessageIds: insight.relatedMessageIds.filter(validMessageIds.contains),
        relatedRequests: insight.relatedRequests,
        ambiguities: insight.ambiguities,
        confidence: min(max(insight.confidence, 0), 1)
      )
    }
    return EvidenceAnalysis(
      id: "evidence_\(UUID().uuidString.lowercased())",
      sourceId: source.id,
      sourceHash: sourceHash,
      facts: toItems(payload.facts, source: .fact),
      requests: toItems(payload.requests, source: .request),
      constraints: toItems(payload.constraints, source: .constraint),
      conditions: toItems(payload.conditions, source: .condition),
      exclusions: toItems(payload.exclusions, source: .exclusion),
      ambiguities: toItems(payload.ambiguities, source: .ambiguity),
      relationships: toItems(payload.relationships, source: .relationship),
      attachmentInsights: insights,
      overallConfidence: payload.overallConfidence.flatMap { min(max($0, 0), 1) }
    )
  }

  func makeWorkspace() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(
      path: "kakaotolinear-ai-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    return url
  }

  func writeOptimizedImages(source: SourceBundle, to directory: URL) -> [URL] {
    let optimizer = AIImageOptimizer()
    var urls: [URL] = []
    for (index, resolved) in source.resolvedAttachments.enumerated()
    where resolved.attachment.kind == .image {
      guard let data = try? optimizer.jpegData(from: resolved.fileURL) else { continue }
      let url = directory.appending(path: "image-\(index).jpg")
      do {
        try data.write(to: url, options: .atomic)
        urls.append(url)
      } catch {
        continue
      }
    }
    return urls
  }

  func cleanup(_ workspace: URL) {
    try? FileManager.default.removeItem(at: workspace)
  }
}
