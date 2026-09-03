import Foundation
import Testing
@testable import KakaoLinearCore

@Suite("2-pass evidence pipeline")
struct EvidencePipelineTests {
  private func root() -> URL {
    FileManager.default.temporaryDirectory.appending(
      path: "kakao-evidence-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
  }

  private func source() -> SourceBundle {
    SourceBundle(
      id: "src_ev",
      room: KakaoRoom(id: "room_1", title: "A업체"),
      messages: [
        KakaoMessage(
          id: "msg_1", roomId: "room_1", senderName: "A",
          timestamp: Date(timeIntervalSince1970: 1_700_000_000), type: .text,
          text: "모바일 버튼 아래로 내려주세요. PC는 그대로입니다.")
      ],
      resolvedAttachments: []
    )
  }

  @Test("analyze는 source가 같으면 cache를 재사용한다")
  func cacheReuse() async throws {
    let store = ArtifactStore(paths: AppSupportPaths(root: root()))
    try await store.saveSource(source())
    let count = CountingProvider()
    let composer = IssueComposer(provider: count, store: store)

    _ = try await composer.analyze(sourceId: "src_ev")
    _ = try await composer.analyze(sourceId: "src_ev")

    #expect(count.analyzeCalls == 1)
  }

  @Test("forceRefresh는 cache를 무시하고 재분석한다")
  func forceRefreshReanalyzes() async throws {
    let store = ArtifactStore(paths: AppSupportPaths(root: root()))
    try await store.saveSource(source())
    let count = CountingProvider()
    let composer = IssueComposer(provider: count, store: store)

    _ = try await composer.analyze(sourceId: "src_ev")
    _ = try await composer.analyze(sourceId: "src_ev", forceRefresh: true)

    #expect(count.analyzeCalls == 2)
  }

  @Test("evidence는 영속화되어 compose에서 재사용된다")
  func persistenceAndReuse() async throws {
    let dir = root()
    let paths = AppSupportPaths(root: dir)
    let store = ArtifactStore(paths: paths)
    try await store.saveSource(source())
    let provider = CountingProvider()
    let composer = IssueComposer(provider: provider, store: store)

    _ = try await composer.compose(sourceId: "src_ev")
    _ = try await composer.compose(sourceId: "src_ev")

    // 첫 compose에서 analyze+mock compose, 두 번째는 cache 재사용 → analyze 1회
    #expect(provider.analyzeCalls == 1)
    let reloaded = ArtifactStore(paths: AppSupportPaths(root: dir))
    #expect(try await reloaded.listEvidence(sourceId: "src_ev").count == 1)
  }

  @Test("semantic validation이 범위 밖 confidence와 source id를 정리한다")
  func semanticValidation() async throws {
    let paths = AppSupportPaths(root: root())
    let store = ArtifactStore(paths: paths)
    try await store.saveSource(source())

    let raw = EvidenceAnalysis(
      id: "evidence_x",
      sourceId: "src_ev",
      sourceHash: "",
      facts: [],
      requests: [
        EvidenceItem(
          id: "r", source: .request, content: "  버튼 이동  ",
          sourceMessageIds: ["msg_1", "msg_does_not_exist"],
          confidence: 1.7)
      ],
      constraints: [],
      conditions: [],
      exclusions: [],
      ambiguities: [],
      relationships: [],
      attachmentInsights: [],
      overallConfidence: 3.0
    )
    try await store.saveEvidence(raw)

    let composer = IssueComposer(provider: CountingProvider(), store: store)
    let analyzed = try await composer.analyze(sourceId: "src_ev")
    let item = try #require(analyzed.requests.first)
    #expect(item.confidence <= 1.0)
    #expect(item.sourceMessageIds == ["msg_1"])
    #expect(analyzed.overallConfidence ?? 1.0 <= 1.0)
  }

  @Test("decode 실패 로그는 별도 ai-errors.log 파일에 기록된다")
  func errorLogFile() throws {
    let dir = root()
    let paths = AppSupportPaths(root: dir)
    AIErrorLogger(paths: paths).logDecodeFailure(
      rawResponse: "{\"facts\":[]}",
      error: KakaoLinearError.internalFailure("test decode")
    )
    let data = try Data(contentsOf: paths.aiErrorLog)
    let text = String(decoding: data, as: UTF8.self)
    #expect(text.contains("structured decode failed"))
    #expect(text.contains("{\"facts\":[]}"))
  }

  @Test("신규 필드가 없는 구형 KakaoMessage JSON도 그대로 디코딩된다")
  func kakaoMessageBackwardCompatible() throws {
    let legacy = Data(
      """
      {"id":"msg_1","roomId":"room_1","senderId":"1","senderName":"김과장",
       "timestamp":"2026-09-02T01:32:00Z","type":"text","text":"안녕하세요","attachments":[]}
      """.utf8)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let message = try decoder.decode(KakaoMessage.self, from: legacy)
    #expect(message.id == "msg_1")
    #expect(message.isMine == false)
    #expect(message.replyQuoteText == nil)
    #expect(message.replyAuthorName == nil)
  }

  @Test("답장 attachment JSON에서 인용 원문과 작성자를 추출한다")
  func replyQuoteParsing() throws {
    let adapter = NativeKakaoArchiveAdapter(
      paths: KakaoPaths(homeDirectory: root(), dataDirectory: root().appending(path: "data")))
    let raw =
      """
      {"reply":{
        "src_logId":1234,
        "src_userId":99,
        "src_userNickName":"관리자",
        "src_message":{"content":"인용할 원문 내용","chatId":9}
      }}
      """
    let quote = adapter.replyQuote(from: raw)
    #expect(quote?.text == "인용할 원문 내용")
    #expect(quote?.authorId == 99)
    #expect(quote?.rawAuthorName == "관리자")
  }

  @Test("content 대신 최상위 message키로 답장 인용을 읽을 수 있다")
  func replyQuoteFallbackKeys() throws {
    let adapter = NativeKakaoArchiveAdapter(
      paths: KakaoPaths(homeDirectory: root(), dataDirectory: root().appending(path: "data")))
    let raw =
      """
      {"reply":{"src_userId":7,"src_message_content":"평면 콘텐츠 인용"}}
      """
    let quote = adapter.replyQuote(from: raw)
    #expect(quote?.text == "평면 콘텐츠 인용")
    #expect(quote?.authorId == 7)
  }
}

private final class CountingProvider: AIProvider, @unchecked Sendable {
  private let lock = NSLock()
  private var _analyzeCalls = 0
  var analyzeCalls: Int {
    lock.withLock { _analyzeCalls }
  }

  func analyzeEvidence(source: SourceBundle, agentsInstructions: String?) async throws
    -> EvidenceAnalysis
  {
    lock.withLock { _analyzeCalls += 1 }
    return EvidenceAnalysis(
      id: "evidence_\(UUID().uuidString.lowercased())",
      sourceId: source.id,
      sourceHash: "",
      facts: [],
      requests: [
        EvidenceItem(
          id: "ev_r_0", source: .request, content: "버튼 이동",
          sourceMessageIds: source.messages.map(\.id))
      ],
      constraints: [
        EvidenceItem(
          id: "ev_c_0", source: .constraint, content: "PC는 그대로",
          sourceMessageIds: source.messages.map(\.id))
      ],
      conditions: [],
      exclusions: [],
      ambiguities: [],
      relationships: [],
      attachmentInsights: [],
      overallConfidence: 0.9
    )
  }

  func composeIssue(
    source: SourceBundle, evidence: EvidenceAnalysis, agentsInstructions: String?
  ) async throws -> IssueDraft {
    IssueDraft(
      id: "draft_\(UUID().uuidString.lowercased())", sourceId: source.id,
      title: "모바일 버튼 위치 수정", summary: "모바일 범위",
      requirements: evidence.requests.map(\.content),
      acceptanceCriteria: ["하단 표시"], sourceMessageIds: source.messages.map(\.id))
  }

  func reviseIssue(
    source: SourceBundle, evidence: EvidenceAnalysis, current: IssueDraft,
    instruction: String, agentsInstructions: String?
  ) async throws -> IssueDraft {
    IssueDraft(
      id: "draft_\(UUID().uuidString.lowercased())", sourceId: source.id,
      revision: current.revision + 1, parentDraftId: current.id,
      title: current.title, summary: instruction,
      requirements: evidence.requests.map(\.content),
      acceptanceCriteria: current.acceptanceCriteria,
      sourceMessageIds: current.sourceMessageIds)
  }

  func healthCheck() async -> Bool { true }
}
