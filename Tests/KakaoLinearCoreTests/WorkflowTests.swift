import Foundation
import Testing
@testable import KakaoLinearCore

@Suite("End-to-end core workflow", .serialized)
struct WorkflowTests {
  @Test("선택한 message만 immutable SourceBundle에 저장한다")
  func sourceSelection() async throws {
    let fixtureURL = try #require(
      Bundle.module.url(forResource: "sample", withExtension: "json", subdirectory: "Fixtures")
    )
    let root = temporaryRoot()
    let store = ArtifactStore(paths: AppSupportPaths(root: root))
    let source = try await SourceService(
      adapter: FixtureKakaoArchiveAdapter(url: fixtureURL),
      store: store
    ).create(
      selection: SourceSelection(
        roomId: "room_123",
        messageIds: ["msg_101", "msg_103"]
      ))

    #expect(source.messages.map(\.id) == ["msg_101", "msg_103"])
    #expect(source.resolvedAttachments.isEmpty)
    let loaded = try await store.loadSource(source.id)
    #expect(loaded == source)
    await #expect(throws: KakaoLinearError.self) {
      try await store.saveSource(source)
    }
  }

  @Test("OpenAI-compatible compose와 revise는 새 revision을 저장한다")
  func composeAndRevise() async throws {
    let root = temporaryRoot()
    let paths = AppSupportPaths(root: root)
    let store = ArtifactStore(paths: paths)
    let source = sampleSource()
    try await store.saveSource(source)
    let provider = MockAIProvider()
    let composer = IssueComposer(provider: provider, store: store)

    let first = try await composer.compose(sourceId: source.id)
    let second = try await composer.revise(draftId: first.id, instruction: "PC 범위 제외")

    #expect(first.revision == 1)
    #expect(second.revision == 2)
    #expect(second.parentDraftId == first.id)
    #expect(try await store.loadSource(source.id) == source)
    #expect(try await store.listDrafts(sourceId: source.id).count == 2)
  }

  @Test("OpenAI-compatible HTTP response를 structured draft로 검증한다")
  func openAIHTTPContract() async throws {
    MockURLProtocol.handler = { request in
      let body = try requestBody(request)
      let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
      #expect(json["model"] as? String == "mock-model")
      let payload: [String: Any] = [
        "title": "모바일 버튼 위치 수정",
        "summary": "모바일 범위만 수정",
        "requirements": ["버튼을 하단으로 이동"],
        "acceptanceCriteria": ["모바일에서 하단에 표시"],
        "notes": [],
        "questions": [],
        "sourceMessageIds": ["msg_101"],
      ]
      let payloadData = try JSONSerialization.data(withJSONObject: payload)
      let content = String(decoding: payloadData, as: UTF8.self)
      return try response(
        url: request.url,
        object: ["choices": [["message": ["content": content]]]]
      )
    }
    let provider = OpenAICompatibleProvider(
      configuration: .init(baseURL: "https://mock.test/v1", model: "mock-model"),
      apiKey: "test",
      session: mockSession()
    )
    let draft = try await provider.composeIssue(
      source: sampleSource(), evidence: sampleEvidence(), agentsInstructions: nil)
    #expect(draft.title == "모바일 버튼 위치 수정")
    #expect(draft.sourceMessageIds == ["msg_101"])
  }

  @Test("Linear create는 attachment를 올리고 같은 draft 중복 생성을 막는다")
  func linearIdempotency() async throws {
    let counter = RequestCounter()
    MockURLProtocol.handler = { request in
      if request.httpMethod == "PUT" {
        counter.incrementUpload()
        return (try http(url: request.url, status: 200), Data())
      }
      let body = try requestBody(request)
      let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
      let query = try #require(object["query"] as? String)
      if query.contains("FileUpload") {
        return try response(
          url: request.url,
          object: [
            "data": [
              "fileUpload": [
                "success": true,
                "uploadFile": [
                  "uploadUrl": "https://upload.test/object",
                  "assetUrl": "https://assets.linear.test/object.png",
                  "headers": [["key": "x-upload", "value": "signed"]],
                ],
              ]
            ]
          ]
        )
      }
      if query.contains("query Issue") {
        return try response(url: request.url, object: ["data": ["issue": NSNull()]])
      }
      if query.contains("IssueCreate") {
        counter.incrementCreate()
        return try response(
          url: request.url,
          object: [
            "data": [
              "issueCreate": [
                "success": true,
                "issue": [
                  "id": "issue-uuid",
                  "identifier": "ENG-382",
                  "url": "https://linear.app/acme/issue/ENG-382/test",
                  "title": "모바일 버튼 위치 수정",
                ],
              ]
            ]
          ]
        )
      }
      throw KakaoLinearError.internalFailure("unexpected mock query")
    }

    let root = temporaryRoot()
    let paths = AppSupportPaths(root: root)
    let store = ArtifactStore(paths: paths)
    var source = sampleSource()
    let attachmentFile = root.appending(path: "screenshot.png")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data([0x89, 0x50, 0x4E, 0x47]).write(to: attachmentFile)
    let attachment = KakaoAttachment(
      id: "att_101_0",
      messageId: "msg_101",
      kind: .image,
      originalName: "screenshot.png",
      mimeType: "image/png",
      fullAvailable: true
    )
    source = SourceBundle(
      id: source.id,
      room: source.room,
      messages: source.messages,
      resolvedAttachments: [
        ResolvedAttachment(
          attachment: attachment,
          fileURL: attachmentFile,
          tier: .localFull,
          sha1: "fixture"
        )
      ]
    )
    try await store.saveSource(source)
    let draft = sampleDraft(sourceId: source.id)
    try await store.saveDraft(draft)
    let client = LinearClient(
      endpoint: try #require(URL(string: "https://api.linear.test/graphql")),
      apiKey: "test",
      session: mockSession()
    )
    let creator = IssueCreator(
      client: client,
      artifacts: store,
      paths: paths,
      defaults: RoomDefaultsStore(paths: paths)
    )
    let result = try await creator.create(
      draftId: draft.id,
      options: LinearIssueOptions(teamId: "team-id", priority: .high)
    )
    #expect(result.identifier == "ENG-382")
    #expect(counter.snapshot() == (uploads: 1, creates: 1))

    do {
      _ = try await creator.create(
        draftId: draft.id,
        options: LinearIssueOptions(teamId: "team-id")
      )
      Issue.record("같은 draft가 중복 생성됨")
    } catch let error as KakaoLinearError {
      #expect(error.exitCode == 60)
    }
    #expect(counter.snapshot() == (uploads: 1, creates: 1))
  }

  @Test("Linear markdown은 요구사항과 원문 provenance를 보존한다")
  func linearDescription() {
    let source = sampleSource()
    let description = LinearDescriptionBuilder().build(
      draft: sampleDraft(sourceId: source.id),
      source: source
    )
    #expect(description.contains("## 요청사항"))
    #expect(description.contains("## 완료 조건"))
    #expect(description.contains("## 원본 요청"))
    #expect(description.contains("`msg_101`"))
  }

  @Test("GUI manual edit는 Linear 단계 전에 새 draft revision으로 고정된다")
  func persistsManualDraftEdits() async throws {
    let store = ArtifactStore(paths: AppSupportPaths(root: temporaryRoot()))
    var original = sampleDraft(sourceId: "src_fixture")
    try await store.saveDraft(original)
    original.title = "사용자가 수정한 제목"

    let reviewed = try await DraftRevisionService(store: store).persistManualEdits(original)

    #expect(reviewed.id != original.id)
    #expect(reviewed.parentDraftId == original.id)
    #expect(reviewed.revision == original.revision + 1)
    #expect(reviewed.title == "사용자가 수정한 제목")
    #expect(try await store.loadDraft(reviewed.id).title == "사용자가 수정한 제목")
  }

  @Test("1000개보다 오래된 range endpoint까지 pagination해서 source를 만든다")
  func sourceSelectionAcrossPages() async throws {
    let store = ArtifactStore(paths: AppSupportPaths(root: temporaryRoot()))
    let source = try await SourceService(adapter: PagedAdapter(), store: store).create(
      selection: SourceSelection(
        roomId: "room_1",
        fromMessageId: "msg_1",
        toMessageId: "msg_1500"
      ))
    #expect(source.messages.count == 1_500)
    #expect(source.messages.first?.id == "msg_1")
    #expect(source.messages.last?.id == "msg_1500")
  }

  @Test("Codex subscription provider는 credential을 읽지 않고 CLI final output을 사용한다")
  func codexCLIProvider() async throws {
    let script = try makeExecutable(
      """
      #!/bin/zsh
      if [[ "$1" == "login" ]]; then exit 0; fi
      output=""
      while [[ $# -gt 0 ]]; do
        if [[ "$1" == "--output-last-message" ]]; then output="$2"; shift 2; continue; fi
        shift
      done
      cat >/dev/null
      print -n '{"title":"Codex draft","summary":"plan","requirements":["one"],"acceptanceCriteria":["done"],"notes":[],"questions":[],"sourceMessageIds":["msg_101"]}' > "$output"
      """
    )
    let provider = CodexCLIProvider(commandPath: script.path, model: "")
    #expect(await provider.healthCheck())
    let draft = try await provider.composeIssue(
      source: sampleSource(), evidence: sampleEvidence(), agentsInstructions: nil)
    #expect(draft.title == "Codex draft")
    #expect(draft.sourceMessageIds == ["msg_101"])
  }

  @Test("OpenCode catalog는 UNKNOWN과 paid model을 fail-closed로 제외한다")
  func openCodeFreeCatalog() async throws {
    MockURLProtocol.handler = { request in
      #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
      let isGo = request.url?.path.contains("/zen/go/") == true
      let entries: [[String: Any]] =
        isGo
        ? [
          ["id": "go-subscription", "pricing": ["input": 0, "output": 0]],
          ["id": "go-preview-free"],
        ]
        : [
          ["id": "big-pickle"],
          ["id": "paid", "cost": ["input": 1, "output": 0]],
          ["id": "zero-price", "pricing": ["input": 0, "output": 0]],
          ["id": "unknown"],
          ["id": "named-free"],
        ]
      return try response(url: request.url, object: ["data": entries])
    }
    let models = try await OpenCodeFreeCatalog(session: mockSession()).models(apiKey: "test-key")
    #expect(
      models.map(\.id) == [
        "go/go-preview-free",
        "zen/big-pickle",
        "zen/named-free",
        "zen/zero-price",
      ])
  }

  @Test("OpenCode Free provider는 catalog 검증 후 endpoint를 직접 호출한다")
  func openCodeFreeDirectProvider() async throws {
    MockURLProtocol.handler = { request in
      if request.httpMethod == "GET" {
        return try response(
          url: request.url,
          object: ["data": [["id": "big-pickle"]]]
        )
      }
      let body = try requestBody(request)
      let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
      #expect(json["model"] as? String == "big-pickle")
      #expect(request.url?.absoluteString == "https://opencode.ai/zen/v1/chat/completions")
      let payload: [String: Any] = [
        "title": "OpenCode draft",
        "summary": "plan",
        "requirements": ["one"],
        "acceptanceCriteria": ["done"],
        "notes": [],
        "questions": [],
        "sourceMessageIds": ["msg_101"],
      ]
      let content = String(
        decoding: try JSONSerialization.data(withJSONObject: payload),
        as: UTF8.self
      )
      return try response(
        url: request.url,
        object: ["choices": [["message": ["content": content]]]]
      )
    }
    let provider = try OpenCodeFreeProvider(
      model: "zen/big-pickle",
      apiKey: "test-key",
      session: mockSession()
    )
    let draft = try await provider.composeIssue(
      source: sampleSource(), evidence: sampleEvidence(), agentsInstructions: nil)
    #expect(draft.title == "OpenCode draft")
  }

  @Test("새 config는 Codex plan이 기본이고 legacy API config는 호환된다")
  func providerConfigurationMigration() throws {
    #expect(AppConfiguration().ai.provider == .codexSubscription)
    let legacy = Data("{\"baseURL\":\"http://localhost:4000/v1\",\"model\":\"legacy\"}".utf8)
    let decoded = try JSONDecoder().decode(AppConfiguration.AI.self, from: legacy)
    #expect(decoded.provider == .openAICompatible)
    #expect(decoded.model == "legacy")
  }

  @Test("AI subprocess timeout은 process를 종료하고 호출자를 반환한다")
  func subprocessTimeout() async throws {
    let script = try makeExecutable(
      """
      #!/bin/zsh
      while true; do :; done
      """
    )
    let started = Date()
    do {
      _ = try await SubprocessRunner().run(
        executable: script,
        arguments: [],
        currentDirectory: script.deletingLastPathComponent(),
        timeout: 0.1
      )
      Issue.record("timeout process가 성공으로 반환됨")
    } catch let error as KakaoLinearError {
      #expect(error.exitCode == 30)
    }
    #expect(Date().timeIntervalSince(started) < 3)
  }

  @Test("Message 선택은 plain/Command/Shift/Command-Shift macOS 규칙을 따른다")
  func messageSelectionModifiers() {
    let ids = (0..<6).map { "msg_\($0)" }
    var result = MessageSelectionPolicy.apply(
      orderedIds: ids,
      current: [],
      anchorIndex: nil,
      clickedIndex: 1,
      modifier: .none
    )
    #expect(result.selectedIds == ["msg_1"])

    result = MessageSelectionPolicy.apply(
      orderedIds: ids,
      current: result.selectedIds,
      anchorIndex: result.anchorIndex,
      clickedIndex: 4,
      modifier: .command
    )
    #expect(result.selectedIds == ["msg_1", "msg_4"])

    result = MessageSelectionPolicy.apply(
      orderedIds: ids,
      current: result.selectedIds,
      anchorIndex: result.anchorIndex,
      clickedIndex: 2,
      modifier: .shift
    )
    #expect(result.selectedIds == ["msg_2", "msg_3", "msg_4"])

    result = MessageSelectionPolicy.apply(
      orderedIds: ids,
      current: result.selectedIds,
      anchorIndex: result.anchorIndex,
      clickedIndex: 0,
      modifier: .commandShift
    )
    #expect(result.selectedIds == ["msg_0", "msg_1", "msg_2", "msg_3", "msg_4"])
  }

  @Test("Room 즐겨찾기는 local store에 유지되고 명시적으로 해제된다")
  func roomFavoritesPersistence() async throws {
    let paths = AppSupportPaths(root: temporaryRoot())
    let store = RoomFavoritesStore(paths: paths)
    #expect(try await store.load().isEmpty)

    #expect(try await store.setFavorite(roomId: "room_123", isFavorite: true) == ["room_123"])
    let reloaded = RoomFavoritesStore(paths: paths)
    #expect(try await reloaded.load() == ["room_123"])

    #expect(try await reloaded.setFavorite(roomId: "room_123", isFavorite: false).isEmpty)
    let attributes = try FileManager.default.attributesOfItem(atPath: paths.roomFavorites.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
  }

  private func temporaryRoot() -> URL {
    FileManager.default.temporaryDirectory.appending(
      path: "kakao-linear-tests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
  }

  private func sampleSource() -> SourceBundle {
    SourceBundle(
      id: "src_fixture",
      room: KakaoRoom(id: "room_123", title: "A업체 개발방"),
      messages: [
        KakaoMessage(
          id: "msg_101",
          roomId: "room_123",
          senderName: "김과장",
          timestamp: Date(timeIntervalSince1970: 1_700_000_000),
          type: .text,
          text: "모바일 버튼을 아래로 내려주세요"
        )
      ],
      resolvedAttachments: []
    )
  }

  private func sampleDraft(sourceId: String) -> IssueDraft {
    IssueDraft(
      id: "draft_fixture",
      sourceId: sourceId,
      title: "모바일 버튼 위치 수정",
      summary: "모바일 화면 범위",
      requirements: ["버튼을 하단으로 이동"],
      acceptanceCriteria: ["모바일에서 하단에 표시"],
      sourceMessageIds: ["msg_101"]
    )
  }

  private func sampleEvidence() -> EvidenceAnalysis {
    EvidenceAnalysis(
      id: "evidence_fixture",
      sourceId: "src_fixture",
      sourceHash: "fixture-hash",
      facts: [],
      requests: [
        EvidenceItem(
          id: "ev_request_0", source: .request, content: "버튼을 하단으로 이동",
          sourceMessageIds: ["msg_101"])
      ],
      constraints: [],
      conditions: [],
      exclusions: [],
      ambiguities: [],
      relationships: [],
      attachmentInsights: [],
      overallConfidence: 0.9
    )
  }

  private func makeExecutable(_ contents: String) throws -> URL {
    let directory = temporaryRoot()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appending(path: "provider")
    try Data(contents.utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
  }

  private func mockSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockURLProtocol.self]
    return URLSession(configuration: configuration)
  }
}

private struct MockAIProvider: AIProvider {
  func analyzeEvidence(
    source: SourceBundle,
    agentsInstructions: String?
  ) async throws -> EvidenceAnalysis {
    EvidenceAnalysis(
      id: "evidence_\(UUID().uuidString)",
      sourceId: source.id,
      sourceHash: "mock",
      facts: [],
      requests: [
        EvidenceItem(
          id: "ev_request_0", source: .request, content: "버튼 이동",
          sourceMessageIds: source.messages.map(\.id))
      ],
      constraints: [],
      conditions: [],
      exclusions: [],
      ambiguities: [],
      relationships: [],
      attachmentInsights: [],
      overallConfidence: 0.9
    )
  }

  func composeIssue(
    source: SourceBundle,
    evidence: EvidenceAnalysis,
    agentsInstructions: String?
  ) async throws -> IssueDraft {
    IssueDraft(
      id: "draft_\(UUID().uuidString)",
      sourceId: source.id,
      title: "모바일 버튼 위치 수정",
      summary: "모바일 범위",
      requirements: evidence.requests.map(\.content),
      acceptanceCriteria: ["하단 표시"],
      sourceMessageIds: source.messages.map(\.id)
    )
  }

  func reviseIssue(
    source: SourceBundle,
    evidence: EvidenceAnalysis,
    current: IssueDraft,
    instruction: String,
    agentsInstructions: String?
  ) async throws -> IssueDraft {
    IssueDraft(
      id: "draft_\(UUID().uuidString)",
      sourceId: source.id,
      revision: current.revision + 1,
      parentDraftId: current.id,
      title: current.title,
      summary: instruction,
      requirements: evidence.requests.map(\.content),
      acceptanceCriteria: current.acceptanceCriteria,
      sourceMessageIds: current.sourceMessageIds
    )
  }

  func healthCheck() async -> Bool { true }
}

private struct PagedAdapter: KakaoArchiveAdapter {
  private var allMessages: [KakaoMessage] {
    (1...1_500).map { index in
      KakaoMessage(
        id: "msg_\(index)",
        roomId: "room_1",
        senderName: "fixture",
        timestamp: Date(timeIntervalSince1970: Double(index)),
        type: .text,
        text: "message \(index)"
      )
    }
  }

  func listRooms(limit: Int, query: String?) throws -> [KakaoRoom] {
    [KakaoRoom(id: "room_1", title: "fixture")]
  }

  func listMessages(
    roomId: String,
    beforeMessageId: String?,
    limit: Int
  ) throws -> [KakaoMessage] {
    let before = beforeMessageId.flatMap { Int($0.dropFirst(4)) }
    return allMessages.filter { message in
      guard let before else { return true }
      return (Int(message.id.dropFirst(4)) ?? .max) < before
    }.suffix(limit).map(\.self)
  }

  func resolveAttachment(
    id: String,
    outputDirectory: URL
  ) async throws -> ResolvedAttachment {
    throw KakaoLinearError.attachmentResolution("no fixtures")
  }

  func databaseIsReadable() -> Bool { true }
}

private final class RequestCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var uploads = 0
  private var creates = 0

  func incrementUpload() { lock.withLock { uploads += 1 } }
  func incrementCreate() { lock.withLock { creates += 1 } }
  func snapshot() -> (uploads: Int, creates: Int) {
    lock.withLock { (uploads, creates) }
  }
}

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
  nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    do {
      let handler = try #require(Self.handler)
      let (response, data) = try handler(request)
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
    } catch {
      client?.urlProtocol(self, didFailWithError: error)
    }
  }

  override func stopLoading() {}
}

private func http(url: URL?, status: Int) throws -> HTTPURLResponse {
  guard let url,
    let response = HTTPURLResponse(
      url: url,
      statusCode: status,
      httpVersion: "HTTP/1.1",
      headerFields: ["Content-Type": "application/json"]
    )
  else {
    throw KakaoLinearError.internalFailure("mock HTTP response")
  }
  return response
}

private func response(url: URL?, object: Any) throws -> (HTTPURLResponse, Data) {
  (try http(url: url, status: 200), try JSONSerialization.data(withJSONObject: object))
}

private func requestBody(_ request: URLRequest) throws -> Data {
  if let body = request.httpBody { return body }
  guard let stream = request.httpBodyStream else {
    throw KakaoLinearError.internalFailure("mock request body is missing")
  }
  stream.open()
  defer { stream.close() }
  var data = Data()
  var buffer = [UInt8](repeating: 0, count: 4_096)
  while stream.hasBytesAvailable {
    let count = stream.read(&buffer, maxLength: buffer.count)
    if count < 0 {
      throw stream.streamError ?? KakaoLinearError.internalFailure("mock body stream")
    }
    if count == 0 { break }
    data.append(contentsOf: buffer.prefix(count))
  }
  return data
}
