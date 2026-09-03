import CryptoKit
import Foundation

public struct OpenAICompatibleProvider: AIProvider {
  private struct Request: Encodable {
    let model: String
    let messages: [Message]
    let responseFormat: ResponseFormat?

    enum CodingKeys: String, CodingKey {
      case model
      case messages
      case responseFormat = "response_format"
    }
  }

  private struct ResponseFormat: Encodable {
    let type: String
  }

  private struct Message: Encodable {
    let role: String
    let content: Content
  }

  private enum Content: Encodable {
    case text(String)
    case parts([ContentPart])

    func encode(to encoder: Encoder) throws {
      var container = encoder.singleValueContainer()
      switch self {
      case let .text(value): try container.encode(value)
      case let .parts(value): try container.encode(value)
      }
    }
  }

  private struct ContentPart: Encodable {
    let type: String
    let text: String?
    let imageURL: ImageURL?

    enum CodingKeys: String, CodingKey {
      case type
      case text
      case imageURL = "image_url"
    }

    static func text(_ value: String) -> ContentPart {
      ContentPart(type: "text", text: value, imageURL: nil)
    }

    static func image(dataURL: String) -> ContentPart {
      ContentPart(type: "image_url", text: nil, imageURL: ImageURL(url: dataURL))
    }
  }

  private struct ImageURL: Encodable {
    let url: String
  }

  private struct Response: Decodable {
    struct Choice: Decodable {
      struct Message: Decodable { let content: String }
      let message: Message
    }
    let choices: [Choice]
  }

  private struct DraftPayload: Codable {
    let title: String
    let summary: String
    let requirements: [String]
    let acceptanceCriteria: [String]
    let notes: [String]?
    let questions: [String]?
    let sourceMessageIds: [String]?
  }

  // PASS 1 evidence payload는 모듈 공용 CLEvidencePayload(관대한 디코딩)를 사용한다.

  private static let evidencePolicy = """
    You are a Senior Requirements Analyst, QA Analyst, and UI/UX Evidence Analyst.
    Extract exhaustive evidence from the KakaoTalk source. Do NOT write a final issue.

    Rules:
    1. Never compress, merge, invent, or finalize requirements.
    2. No implementation details (APIs, DB, CSS, components, architecture).
    3. Explicit content → facts / requests / constraints / exclusions / conditions.
    4. Uncertain → ambiguities, never facts.
    5. Connect messages: questions, answers, and revisions overriding earlier messages.
       Preserve scope/exclusion verbatim (e.g. "PC는 그대로", "모바일만").
    6. For each image: screen, important UI elements, annotations (red box/arrow/circle/underline),
       embedded text, error messages, button/field/layout position, current UI state, and how it maps to
       message text like "여기 / 이 부분 / 이 버튼". Never just caption the image.
    7. Image vs text conflict → ambiguity, not arbitrary resolution.
    8. Reference sourceMessageIds, and attachmentIds when from an attachment.
    9. Fill attachmentInsights so the user can verify each attachment was understood.
    10. Respond with JSON only using the keys: facts, requests, constraints, conditions, exclusions,
        ambiguities, relationships, attachmentInsights, overallConfidence.
    """

  private static let synthesisPolicy = """
    You are a Senior Product / Requirements Analyst.
    Produce a Linear issue a developer can work from. You have BOTH the original source and PASS 1 evidence.
    Re-read the original when needed.

    Policy:
    1. Explicit content → requirements / scope / constraints.
    2. High-probability interpretation → notes, not requirements.
    3. Cannot confirm → questions.
    4. Do not invent acceptance criteria absent from the source.
    5. Preserve exclusions exactly (e.g. "PC is unchanged").
    6. Cover: what to change, current problem, desired behavior, platform/screen scope, what must NOT change,
       what each attachment shows, acceptance basis, open questions.
    7. Preserve provenance via sourceMessageIds where possible.
    8. Respond with JSON only using keys: title, summary, requirements, acceptanceCriteria, notes, questions, sourceMessageIds.
    """

  private let configuration: AppConfiguration.AI
  private let apiKey: String?
  private let session: URLSession

  public init(
    configuration: AppConfiguration.AI,
    apiKey: String?,
    session: URLSession = .shared
  ) {
    self.configuration = configuration
    self.apiKey = apiKey
    self.session = session
  }

  public func analyzeEvidence(
    source: SourceBundle,
    agentsInstructions: String?
  ) async throws -> EvidenceAnalysis {
    let content = try await completeRaw(
      system: keyedSystem(Self.evidencePolicy, agentsInstructions: agentsInstructions),
      userText: keyedUserText(
        source: source, evidence: nil, current: nil, instruction: nil,
        agentsInstructions: agentsInstructions),
      source: source
    )
    let decoded = try decodeEvidence(content)
    return makeEvidence(payload: decoded, source: source, sourceHash: try sourceHash(source))
  }

  public func composeIssue(
    source: SourceBundle,
    evidence: EvidenceAnalysis,
    agentsInstructions: String?
  ) async throws -> IssueDraft {
    let payload = try await complete(
      source: source,
      evidence: evidence,
      current: nil,
      instruction: nil,
      agentsInstructions: agentsInstructions
    )
    return makeDraft(payload: payload, source: source, current: nil)
  }

  public func reviseIssue(
    source: SourceBundle,
    evidence: EvidenceAnalysis,
    current: IssueDraft,
    instruction: String,
    agentsInstructions: String?
  ) async throws -> IssueDraft {
    let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw KakaoLinearError.invalidInput("revision instruction은 비어 있을 수 없습니다.")
    }
    let payload = try await complete(
      source: source,
      evidence: evidence,
      current: current,
      instruction: trimmed,
      agentsInstructions: agentsInstructions
    )
    return makeDraft(payload: payload, source: source, current: current)
  }

  public func healthCheck() async -> Bool {
    guard var base = URL(string: configuration.baseURL) else { return false }
    if base.path.hasSuffix("/chat/completions") {
      base.deleteLastPathComponent()
      base.deleteLastPathComponent()
    }
    var request = URLRequest(url: base.appending(path: "models"))
    request.timeoutInterval = 5
    if let apiKey, !apiKey.isEmpty {
      request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    }
    do {
      let (_, response) = try await session.data(for: request)
      return (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
    } catch {
      return false
    }
  }

  private func complete(
    source: SourceBundle,
    evidence: EvidenceAnalysis,
    current: IssueDraft?,
    instruction: String?,
    agentsInstructions: String?
  ) async throws -> DraftPayload {
    let content = try await completeRaw(
      system: keyedSystem(Self.synthesisPolicy, agentsInstructions: agentsInstructions),
      userText: keyedUserText(
        source: source, evidence: evidence, current: current, instruction: instruction,
        agentsInstructions: agentsInstructions),
      source: source
    )
    return try decodePayload(content)
  }

  /// PASS 1/2 공통 raw 응답 호출. 이미지가 있으면 vision input으로 함께 전달한다.
  private func completeRaw(
    system: String,
    userText: String,
    source: SourceBundle
  ) async throws -> String {
    guard let endpoint = endpointURL() else {
      throw KakaoLinearError.aiProvider("AI base URL이 올바르지 않습니다.")
    }
    let model =
      configuration.visionModel.flatMap { source.resolvedAttachments.containsImage ? $0 : nil }
      ?? configuration.model
    let userContent: Content =
      configuration.visionModel == nil ? .text(userText) : imageContent(userText, source: source)
    let messages = [
      Message(role: "system", content: .text(system)),
      Message(role: "user", content: userContent),
    ]
    var (data, response) = try await send(
      endpoint: endpoint,
      body: Request(
        model: model,
        messages: messages,
        responseFormat: ResponseFormat(type: "json_object")
      )
    )
    if let http = response as? HTTPURLResponse, [400, 404, 422].contains(http.statusCode) {
      (data, response) = try await send(
        endpoint: endpoint,
        body: Request(model: model, messages: messages, responseFormat: nil)
      )
    }
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      throw KakaoLinearError.aiProvider("AI provider가 요청을 거부했습니다.")
    }
    let decoded: Response
    do {
      decoded = try JSONDecoder().decode(Response.self, from: data)
    } catch {
      throw KakaoLinearError.aiProvider("AI provider 응답 형식을 읽지 못했습니다.")
    }
    guard let content = decoded.choices.first?.message.content else {
      throw KakaoLinearError.aiProvider("AI provider가 빈 응답을 반환했습니다.")
    }
    return content
  }

  private func send(
    endpoint: URL,
    body: Request
  ) async throws -> (Data, URLResponse) {
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.timeoutInterval = 120
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    if let apiKey, !apiKey.isEmpty {
      request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    }
    request.httpBody = try JSONEncoder().encode(body)
    return try await session.data(for: request)
  }

  private func keyedSystem(_ policy: String, agentsInstructions: String?) -> String {
    var content = policy
    let trimmed = agentsInstructions?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !trimmed.isEmpty {
      content += "\n\nPRECEDING GUIDELINES (AGENTS.md):\n\(trimmed)"
    }
    return content
  }

  private func keyedUserText(
    source: SourceBundle,
    evidence: EvidenceAnalysis?,
    current: IssueDraft?,
    instruction: String?,
    agentsInstructions: String?
  ) -> String {
    var text = SourcePromptFormatter().format(source)
    if let evidence {
      let data = try? JSONEncoder.kakaoLinear.encode(evidence)
      text += "\n\nPASS 1 EVIDENCE ANALYSIS:\n\(String(decoding: data ?? Data(), as: UTF8.self))"
    }
    if let current {
      let currentData = try? JSONEncoder.kakaoLinear.encode(current)
      text += "\n\nCURRENT DRAFT:\n\(String(decoding: currentData ?? Data(), as: UTF8.self))"
    }
    if let instruction {
      text += "\n\nUSER REVISION INSTRUCTION:\n\(instruction)"
    }
    text += (try? TextAttachmentExtractor().context(from: source.resolvedAttachments)) ?? ""
    return text
  }

  private func imageContent(_ text: String, source: SourceBundle) -> Content {
    var parts: [ContentPart] = [.text(text)]
    let optimizer = AIImageOptimizer()
    for resolved in source.resolvedAttachments where resolved.attachment.kind == .image {
      if let data = try? optimizer.jpegData(from: resolved.fileURL) {
        parts.append(.image(dataURL: "data:image/jpeg;base64,\(data.base64EncodedString())"))
      }
    }
    return .parts(parts)
  }

  private func decodePayload(_ content: String) throws -> DraftPayload {
    var json = content.trimmingCharacters(in: .whitespacesAndNewlines)
    if json.hasPrefix("```") {
      json = json.replacingOccurrences(of: "```json", with: "")
        .replacingOccurrences(of: "```", with: "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard let data = json.data(using: .utf8) else {
      throw KakaoLinearError.aiProvider("AI JSON을 UTF-8로 변환하지 못했습니다.")
    }
    do {
      let payload = try JSONDecoder().decode(DraftPayload.self, from: data)
      guard !payload.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw KakaoLinearError.aiProvider("AI draft title이 비어 있습니다.")
      }
      return payload
    } catch let error as KakaoLinearError {
      throw error
    } catch {
      throw KakaoLinearError.aiProvider("AI가 structured draft JSON을 반환하지 않았습니다.")
    }
  }

  private func decodeEvidence(_ content: String) throws -> CLEvidencePayload {
    var json = content.trimmingCharacters(in: .whitespacesAndNewlines)
    if json.hasPrefix("```") {
      json = json.replacingOccurrences(of: "```json", with: "")
        .replacingOccurrences(of: "```", with: "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard let data = json.data(using: .utf8) else {
      throw KakaoLinearError.aiProvider("AI JSON을 UTF-8로 변환하지 못했습니다.")
    }
    do {
      let payload = try JSONDecoder().decode(CLEvidencePayload.self, from: data)
      return payload
    } catch {
      // structured decode 실패 시 raw 응답을 별도 에러로그 파일(ai-errors.log)에 남긴다.
      AIErrorLogger().logDecodeFailure(rawResponse: json, error: error)
      throw KakaoLinearError.aiProvider("AI가 structured evidence JSON을 반환하지 않았습니다.")
    }
  }

  private func sourceHash(_ source: SourceBundle) throws -> String {
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

  private func makeEvidence(
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

  private func makeDraft(
    payload: DraftPayload,
    source: SourceBundle,
    current: IssueDraft?
  ) -> IssueDraft {
    let validIds = Set(source.messages.map(\.id))
    let requested = payload.sourceMessageIds ?? []
    let traced = requested.filter(validIds.contains)
    return IssueDraft(
      id: "draft_\(UUID().uuidString.lowercased())",
      sourceId: source.id,
      revision: (current?.revision ?? 0) + 1,
      parentDraftId: current?.id,
      title: payload.title,
      summary: payload.summary,
      requirements: payload.requirements,
      acceptanceCriteria: payload.acceptanceCriteria,
      notes: payload.notes ?? [],
      questions: payload.questions ?? [],
      sourceMessageIds: traced.isEmpty ? source.messages.map(\.id) : traced
    )
  }

  private func endpointURL() -> URL? {
    guard let base = URL(string: configuration.baseURL),
      ["http", "https"].contains(base.scheme?.lowercased())
    else { return nil }
    if base.path.hasSuffix("/chat/completions") { return base }
    return base.appending(path: "chat/completions")
  }
}

private extension Array where Element == ResolvedAttachment {
  var containsImage: Bool { contains { $0.attachment.kind == .image } }
}
