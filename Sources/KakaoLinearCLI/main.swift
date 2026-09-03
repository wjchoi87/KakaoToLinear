import Darwin
import Foundation
import KakaoLinearCore

@main
struct KakaoLinearCommand {
  private static let runtime = KakaoLinearRuntime()

  static func main() async {
    do {
      try await run(arguments: Array(CommandLine.arguments.dropFirst()))
    } catch let error as KakaoLinearError {
      FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
      exit(error.exitCode)
    } catch {
      FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
      exit(1)
    }
  }

  private static func run(arguments: [String]) async throws {
    guard let command = arguments.first else { return printHelp() }
    let rest = Array(arguments.dropFirst())
    switch command {
    case "doctor": try await runDoctor(arguments: rest)
    case "rooms": try await runRooms(arguments: rest)
    case "messages": try runMessages(arguments: rest)
    case "attachment": try await runAttachment(arguments: rest)
    case "source": try await runSource(arguments: rest)
    case "analyze": try await runAnalyze(arguments: rest)
    case "compose": try await runCompose(arguments: rest)
    case "revise": try await runRevise(arguments: rest)
    case "linear": try await runLinear(arguments: rest)
    case "ai": try await runAI(arguments: rest)
    case "config": try await runConfig(arguments: rest)
    case "auth": try await runAuth(arguments: rest)
    case "issue": try await runIssue(arguments: rest)
    case "help", "--help", "-h": printHelp()
    case "version", "--version": print("kakao-linear 0.2.0")
    default: throw KakaoLinearError.invalidInput("알 수 없는 command입니다: \(command)")
    }
  }

  private static func runDoctor(arguments: [String]) async throws {
    let options = try Options(arguments)
    let adapter = try makeAdapter(options: options)
    let ai = try? await runtime.aiProvider()
    let linear = try? await runtime.linearClient()
    let report = await DoctorService().run(
      adapter: adapter,
      aiProvider: ai,
      linearClient: linear
    )
    if options.flag("--human") {
      for row in [
        ("KakaoTalk", report.kakaoRunning),
        ("Accessibility", report.accessibility),
        ("Full Disk Access", report.fullDiskAccess),
        ("Kakao DB", report.kakaoDatabase),
        ("Linear API", report.linear),
        ("AI Provider", report.ai),
      ] {
        print("[\(row.1 ? "✓" : "✗")] \(row.0)")
      }
    } else {
      try printJSON(APIEnvelope(data: report))
    }
  }

  private static func runRooms(arguments: [String]) async throws {
    guard let action = arguments.first else {
      throw KakaoLinearError.invalidInput(
        "사용법: kakao-linear rooms <list|current|favorites|favorite|unfavorite>"
      )
    }
    let options = try Options(Array(arguments.dropFirst()))
    let adapter = try makeAdapter(options: options)
    switch action {
    case "list":
      let rooms = try adapter.listRooms(
        limit: try options.integer("--limit", default: 30),
        query: options.value("--query")
      )
      if options.flag("--json") {
        try printJSON(APIEnvelope(data: rooms))
      } else {
        rooms.forEach { print("\($0.id)\t\($0.title)\t\($0.lastActivityAt.map(iso8601) ?? "-")") }
      }
    case "current":
      guard let room = try adapter.currentRoom() else {
        throw KakaoLinearError.roomNotFound("current")
      }
      if options.flag("--json") {
        try printJSON(APIEnvelope(data: room))
      } else {
        print("\(room.id)\t\(room.title)")
      }
    case "favorites":
      let favoriteIds = try await runtime.roomFavorites.load()
      let rooms = try adapter.listRooms(
        limit: try options.integer("--limit", default: 1_000),
        query: options.value("--query")
      ).filter { favoriteIds.contains($0.id) }
      if options.flag("--json") {
        try printJSON(APIEnvelope(data: rooms))
      } else {
        for room in rooms { print("\(room.id)\t\(room.title)") }
      }
    case "favorite", "unfavorite":
      let roomId = try options.required("--room")
      guard try adapter.listRooms(limit: 1_000, query: nil).contains(where: { $0.id == roomId })
      else {
        throw KakaoLinearError.roomNotFound(roomId)
      }
      let isFavorite = action == "favorite"
      _ = try await runtime.roomFavorites.setFavorite(
        roomId: roomId,
        isFavorite: isFavorite
      )
      let result = RoomFavoriteUpdate(roomId: roomId, isFavorite: isFavorite)
      if options.flag("--json") {
        try printJSON(APIEnvelope(data: result))
      } else {
        print("\(roomId)\t\(isFavorite ? "favorite" : "not-favorite")")
      }
    default:
      throw KakaoLinearError.invalidInput("지원하지 않는 rooms action입니다: \(action)")
    }
  }

  private static func runMessages(arguments: [String]) throws {
    guard arguments.first == "list" else {
      throw KakaoLinearError.invalidInput("사용법: kakao-linear messages list --room <id>")
    }
    let options = try Options(Array(arguments.dropFirst()))
    let roomId = try options.required("--room")
    let messages = try makeAdapter(options: options).listMessages(
      roomId: roomId,
      beforeMessageId: options.value("--before"),
      limit: try options.integer("--limit", default: 100)
    )
    if options.flag("--json") {
      try printJSON(APIEnvelope(data: messages))
    } else {
      for message in messages {
        print(
          "\(message.id)\t\(iso8601(message.timestamp))\t\(message.senderName)\t\(message.text ?? "[\(message.type.rawValue)]")"
        )
      }
    }
  }

  private static func runAttachment(arguments: [String]) async throws {
    guard arguments.first == "get" else {
      throw KakaoLinearError.invalidInput(
        "사용법: kakao-linear attachment get --id <id> --output <dir>")
    }
    let options = try Options(Array(arguments.dropFirst()))
    let resolved = try await makeAdapter(options: options).resolveAttachment(
      id: try options.required("--id"),
      outputDirectory: URL(fileURLWithPath: try options.required("--output"), isDirectory: true)
    )
    if options.flag("--json") {
      try printJSON(APIEnvelope(data: resolved))
    } else {
      print(resolved.fileURL.path)
    }
  }

  private static func runSource(arguments: [String]) async throws {
    guard arguments.first == "create" else {
      throw KakaoLinearError.invalidInput(
        "사용법: kakao-linear source create --room <id> --message <id>...")
    }
    let options = try Options(Array(arguments.dropFirst()))
    let source = try await SourceService(
      adapter: makeAdapter(options: options),
      store: runtime.artifacts
    ).create(
      selection: SourceSelection(
        roomId: try options.required("--room"),
        messageIds: options.values("--message"),
        fromMessageId: options.value("--from"),
        toMessageId: options.value("--to")
      ))
    let result = SourceCreateResult(source: source)
    if options.flag("--json") {
      try printJSON(APIEnvelope(data: result))
    } else {
      print(
        "\(result.sourceId) messages=\(result.messageCount) attachments=\(result.attachmentCount) failures=\(result.attachmentFailureCount)"
      )
    }
  }

  private static func runAnalyze(arguments: [String]) async throws {
    let options = try Options(arguments)
    let sourceId = try options.required("--source")
    let config = try await runtime.configuration.load()
    let provider = try await runtime.aiProvider()
    let composer = IssueComposer(provider: provider, store: runtime.artifacts)
    let analysis = try await composer.analyze(
      sourceId: sourceId,
      agentsInstructions: config.linear.agentsMd,
      forceRefresh: options.flag("--force-analyze")
    )
    if options.flag("--json") {
      try printJSON(APIEnvelope(data: analysis))
    } else {
      printEvidence(analysis)
    }
  }

  private static func runCompose(arguments: [String]) async throws {
    let options = try Options(arguments)
    let provider = try await runtime.aiProvider()
    let config = try await runtime.configuration.load()
    let evidenceArg = options.value("--evidence")
    var evidence: EvidenceAnalysis?
    if let id = evidenceArg { evidence = try await runtime.artifacts.loadEvidence(id) }
    let draft = try await IssueComposer(provider: provider, store: runtime.artifacts).compose(
      sourceId: try options.required("--source"),
      agentsInstructions: config.linear.agentsMd,
      evidence: evidence
    )
    if options.flag("--json") { try printJSON(APIEnvelope(data: draft)) } else { printDraft(draft) }
  }

  private static func runRevise(arguments: [String]) async throws {
    let options = try Options(arguments)
    let instruction: String
    if options.flag("--stdin") {
      instruction = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
    } else {
      instruction = try options.required("--instruction")
    }
    let provider = try await runtime.aiProvider()
    let config = try await runtime.configuration.load()
    let evidenceArg = options.value("--evidence")
    var evidence: EvidenceAnalysis?
    if let id = evidenceArg { evidence = try await runtime.artifacts.loadEvidence(id) }
    let draft = try await IssueComposer(provider: provider, store: runtime.artifacts).revise(
      draftId: try options.required("--draft"),
      instruction: instruction,
      agentsInstructions: config.linear.agentsMd,
      evidence: evidence
    )
    if options.flag("--json") { try printJSON(APIEnvelope(data: draft)) } else { printDraft(draft) }
  }

  private static func runLinear(arguments: [String]) async throws {
    guard let action = arguments.first else {
      throw KakaoLinearError.invalidInput(
        "사용법: kakao-linear linear <teams|projects|statuses|members|labels|create>")
    }
    let options = try Options(Array(arguments.dropFirst()))
    let client = try await runtime.linearClient()
    let repository = MetadataRepository(client: client)
    let refresh = options.flag("--refresh")
    switch action {
    case "teams":
      try outputMetadata(try await repository.teams(refresh: refresh), options: options)
    case "projects":
      let teamId = try await resolveTeam(options: options, repository: repository)
      try outputMetadata(
        try await repository.projects(teamId: teamId, refresh: refresh), options: options)
    case "statuses":
      let teamId = try await resolveTeam(options: options, repository: repository)
      try outputMetadata(
        try await repository.statuses(teamId: teamId, refresh: refresh), options: options)
    case "members":
      let teamId = try await resolveTeam(options: options, repository: repository)
      try outputMetadata(
        try await repository.members(teamId: teamId, refresh: refresh), options: options)
    case "labels":
      let teamId = try await resolveTeam(options: options, repository: repository)
      try outputMetadata(
        try await repository.labels(teamId: teamId, refresh: refresh), options: options)
    case "create":
      let teamId = try await resolveTeam(options: options, repository: repository)
      let issueOptions = try linearOptions(options, teamId: teamId)
      let creator = IssueCreator(
        client: client, artifacts: runtime.artifacts, defaults: runtime.roomDefaults)
      if options.flag("--dry-run") {
        let result = try await creator.dryRun(
          draftId: try options.required("--draft"), options: issueOptions)
        try printJSON(APIEnvelope(data: result))
      } else {
        let result = try await creator.create(
          draftId: try options.required("--draft"),
          options: issueOptions,
          force: options.flag("--force")
        )
        if options.flag("--json") {
          try printJSON(APIEnvelope(data: result))
        } else {
          print("\(result.identifier)\t\(result.url.absoluteString)")
        }
      }
    default:
      throw KakaoLinearError.invalidInput("지원하지 않는 linear action입니다: \(action)")
    }
  }

  private static func runConfig(arguments: [String]) async throws {
    guard let action = arguments.first else {
      throw KakaoLinearError.invalidInput("사용법: kakao-linear config <show|set>")
    }
    switch action {
    case "show":
      try printJSON(APIEnvelope(data: try await runtime.configuration.load()))
    case "set":
      guard arguments.count == 3 else {
        throw KakaoLinearError.invalidInput("사용법: kakao-linear config set <key> <value>")
      }
      let config = try await runtime.configuration.set(key: arguments[1], value: arguments[2])
      try printJSON(APIEnvelope(data: config))
    default:
      throw KakaoLinearError.invalidInput("지원하지 않는 config action입니다: \(action)")
    }
  }

  private static func runAI(arguments: [String]) async throws {
    guard let action = arguments.first else {
      throw KakaoLinearError.invalidInput("사용법: kakao-linear ai <providers|models|use|health>")
    }
    let options = try Options(Array(arguments.dropFirst()))
    let catalog = AIProviderCatalog()
    switch action {
    case "providers":
      let providers = catalog.providers()
      if options.flag("--json") {
        try printJSON(APIEnvelope(data: providers))
      } else {
        providers.forEach { print("\($0.id)\t\($0.name)\tsetup: \($0.setupHint)") }
      }
    case "models":
      let config = try await runtime.configuration.load()
      let provider = try providerKind(options.value("--provider") ?? config.ai.provider.rawValue)
      let models = try await catalog.models(
        provider: provider,
        baseURL: provider == config.ai.provider
          ? config.ai.baseURL : provider.suggestedBaseURL,
        apiKey: try runtime.aiSecret(for: provider),
        configuredModel: config.ai.model
      )
      if options.flag("--json") {
        try printJSON(APIEnvelope(data: models))
      } else {
        models.forEach { print("\($0.id)\t\($0.name)") }
      }
    case "use":
      let provider = try providerKind(try options.required("--provider"))
      var config = try await runtime.configuration.load()
      config.ai.provider = provider
      config.ai.model = options.value("--model") ?? provider.suggestedModel
      if !provider.suggestedBaseURL.isEmpty { config.ai.baseURL = provider.suggestedBaseURL }
      try await runtime.configuration.save(config)
      try printJSON(APIEnvelope(data: config.ai))
    case "health":
      let provider = try await runtime.aiProvider()
      try printJSON(APIEnvelope(data: ["available": await provider.healthCheck()]))
    default:
      throw KakaoLinearError.invalidInput("지원하지 않는 ai action입니다: \(action)")
    }
  }

  private static func runAuth(arguments: [String]) async throws {
    guard let target = arguments.first else {
      throw KakaoLinearError.invalidInput("사용법: kakao-linear auth <linear|ai>")
    }
    switch target {
    case "linear":
      guard let pointer = getpass("Linear API key: ") else {
        throw KakaoLinearError.invalidInput("secret 입력을 읽지 못했습니다.")
      }
      try runtime.secrets.set(String(cString: pointer), for: .linearAPIKey)
      print("Keychain에 저장했습니다.")
    case "ai":
      let config = try await runtime.configuration.load()
      if config.ai.provider == .codexSubscription {
        print("Codex subscription credential은 KakaoLinear가 저장하지 않습니다.")
        print("설정 명령: codex login")
        return
      }
      guard let pointer = getpass("\(config.ai.provider.displayName) key (없으면 '-' 입력): ") else {
        throw KakaoLinearError.invalidInput("secret 입력을 읽지 못했습니다.")
      }
      let value = String(cString: pointer)
      try runtime.setAISecret(value == "-" ? "" : value, for: config.ai.provider)
      print(value == "-" ? "Keychain secret을 제거했습니다." : "Keychain에 저장했습니다.")
    default: throw KakaoLinearError.invalidInput("지원하지 않는 auth target입니다: \(target)")
    }
  }

  private static func providerKind(_ value: String) throws -> AIProviderKind {
    guard let provider = AIProviderKind(rawValue: value) else {
      throw KakaoLinearError.invalidInput(
        "지원하지 않는 AI provider입니다: \(value)"
      )
    }
    return provider
  }

  private static func runIssue(arguments: [String]) async throws {
    guard let action = arguments.first else {
      throw KakaoLinearError.invalidInput("사용법: kakao-linear issue <prepare|create>")
    }
    let options = try Options(Array(arguments.dropFirst()))
    switch action {
    case "prepare":
      let adapter = try makeAdapter(options: options)
      let roomId: String
      if options.value("--room") == "current" {
        guard let current = try adapter.currentRoom() else {
          throw KakaoLinearError.roomNotFound("current")
        }
        roomId = current.id
      } else {
        roomId = try options.required("--room")
      }
      let source = try await SourceService(adapter: adapter, store: runtime.artifacts).create(
        selection: SourceSelection(
          roomId: roomId,
          messageIds: options.values("--message"),
          fromMessageId: options.value("--from"),
          toMessageId: options.value("--to")
        ))
      let config = try await runtime.configuration.load()
      let draft = try await IssueComposer(
        provider: runtime.aiProvider(),
        store: runtime.artifacts
      ).compose(
        sourceId: source.id,
        agentsInstructions: config.linear.agentsMd
      )
      try printJSON(APIEnvelope(data: draft))
    case "create":
      let draftId = try options.required("--draft")
      if options.value("--defaults") == "room" {
        let draft = try await runtime.artifacts.loadDraft(draftId)
        let source = try await runtime.artifacts.loadSource(draft.sourceId)
        guard let saved = try await runtime.roomDefaults.get(roomId: source.room.id) else {
          throw KakaoLinearError.invalidInput("이 room에 저장된 Linear defaults가 없습니다.")
        }
        let client = try await runtime.linearClient()
        let result = try await IssueCreator(
          client: client,
          artifacts: runtime.artifacts,
          defaults: runtime.roomDefaults
        ).create(draftId: draftId, options: saved.options, force: options.flag("--force"))
        try printJSON(APIEnvelope(data: result))
      } else {
        try await runLinear(arguments: ["create"] + Array(arguments.dropFirst()))
      }
    default:
      throw KakaoLinearError.invalidInput("지원하지 않는 issue action입니다: \(action)")
    }
  }

  private static func resolveTeam(
    options: Options,
    repository: MetadataRepository
  ) async throws -> String {
    let requested = try options.required("--team")
    let teams = try await repository.teams()
    guard let team = teams.first(where: { $0.id == requested || $0.key == requested }) else {
      throw KakaoLinearError.invalidInput("Linear team을 찾지 못했습니다: \(requested)")
    }
    return team.id
  }

  private static func linearOptions(_ options: Options, teamId: String) throws -> LinearIssueOptions
  {
    let priority = LinearPriority(rawValue: options.value("--priority") ?? "none")
    guard let priority else {
      throw KakaoLinearError.invalidInput("priority는 none/urgent/high/medium/low 중 하나여야 합니다.")
    }
    return LinearIssueOptions(
      teamId: teamId,
      projectId: options.value("--project"),
      statusId: options.value("--status"),
      assigneeId: options.value("--assignee"),
      priority: priority,
      labelIds: options.values("--label")
    )
  }

  private static func makeAdapter(options: Options) throws -> any KakaoArchiveAdapter {
    if let fixture = options.value("--fixture") {
      return try FixtureKakaoArchiveAdapter(url: URL(fileURLWithPath: fixture))
    }
    return NativeKakaoArchiveAdapter()
  }

  private static func outputMetadata<Value: Codable & Sendable & Identifiable>(
    _ values: [Value],
    options: Options
  ) throws {
    if options.flag("--json") {
      try printJSON(APIEnvelope(data: values))
    } else {
      values.forEach { print("\($0.id)") }
    }
  }

  private static func printDraft(_ draft: IssueDraft) {
    print("\(draft.id)\n\(draft.title)\n\n\(draft.summary)")
  }

  private static func printEvidence(_ analysis: EvidenceAnalysis) {
    print("\(analysis.id)  source=\(analysis.sourceId) hash=\(analysis.sourceHash.prefix(8))")
    func dump(_ title: String, _ items: [EvidenceItem]) {
      guard !items.isEmpty else { return }
      print("\n[\(title)]")
      for item in items {
        let score = Int((item.confidence * 100).rounded())
        let refs = (item.sourceMessageIds + item.attachmentIds).joined(separator: ", ")
        print("  - \(item.content) (conf=\(score) refs=\(refs))")
      }
    }
    dump("facts", analysis.facts)
    dump("requests", analysis.requests)
    dump("constraints", analysis.constraints)
    dump("conditions", analysis.conditions)
    dump("exclusions", analysis.exclusions)
    dump("ambiguities", analysis.ambiguities)
    dump("relationships", analysis.relationships)
    for insight in analysis.attachmentInsights {
      print("\n[attachment \(insight.attachmentId) (\(insight.type))]")
      for observation in insight.observations { print("  - \(observation)") }
    }
    if let confidence = analysis.overallConfidence {
      print("\noverallConfidence = \(Int((confidence * 100).rounded()))")
    }
  }

  private static func printJSON<Value: Codable & Sendable>(_ value: Value) throws {
    let data = try JSONEncoder.kakaoLinear.encode(value)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
  }

  private static func iso8601(_ date: Date) -> String {
    ISO8601DateFormatter().string(from: date)
  }

  private static func printHelp() {
    print(
      """
      kakao-linear — KakaoTalk → Linear Issue Maker

      Kakao:
        doctor [--human]
        rooms list|current|favorites
        rooms favorite|unfavorite --room <id>
        messages list --room <id> [--before <id>] [--limit 100]
        attachment get --id <id> --output <dir>

      Draft:
        source create --room <id> --message <id>... | --from <id> --to <id>
        analyze --source <id> [--force-analyze] [--json]
        compose --source <id> [--evidence <id>]
        revise --draft <id> --instruction <text> | --stdin [--evidence <id>]

      Linear:
        linear teams
        linear projects|statuses|members|labels --team <key-or-id>
        linear create --draft <id> --team <key-or-id> [metadata options] [--dry-run]

      Setup:
        ai providers [--json]
        ai models [--provider <id>] [--json]
        ai use --provider <id> [--model <id>]
        ai health
        config show
        config set <ai.provider|ai.base-url|ai.model|ai.vision-model|ai.command-path|linear.endpoint|linear.team|hotkey.key-code|hotkey.modifiers> <value>
        auth <ai|linear>

      모든 list/create command는 --json을 지원하며 JSON schemaVersion은 1이다.
      """)
  }
}

private struct Options: Sendable {
  private let storage: [String: [String]]
  private let flags: Set<String>

  init(_ arguments: [String]) throws {
    let booleanFlags = Set([
      "--json", "--human", "--stdin", "--dry-run", "--force", "--refresh", "--force-analyze",
    ])
    var storage: [String: [String]] = [:]
    var flags = Set<String>()
    var index = 0
    while index < arguments.count {
      let key = arguments[index]
      guard key.hasPrefix("--") else {
        throw KakaoLinearError.invalidInput("예상하지 못한 argument입니다: \(key)")
      }
      if booleanFlags.contains(key) {
        flags.insert(key)
        index += 1
      } else {
        guard index + 1 < arguments.count else {
          throw KakaoLinearError.invalidInput("\(key)에 값이 필요합니다.")
        }
        storage[key, default: []].append(arguments[index + 1])
        index += 2
      }
    }
    self.storage = storage
    self.flags = flags
  }

  func value(_ key: String) -> String? { storage[key]?.last }
  func values(_ key: String) -> [String] { storage[key] ?? [] }
  func flag(_ key: String) -> Bool { flags.contains(key) }

  func required(_ key: String) throws -> String {
    guard let value = value(key), !value.isEmpty else {
      throw KakaoLinearError.invalidInput("\(key)가 필요합니다.")
    }
    return value
  }

  func integer(_ key: String, default defaultValue: Int) throws -> Int {
    guard let raw = value(key) else { return defaultValue }
    guard let value = Int(raw) else {
      throw KakaoLinearError.invalidInput("\(key)는 정수여야 합니다.")
    }
    return value
  }
}
