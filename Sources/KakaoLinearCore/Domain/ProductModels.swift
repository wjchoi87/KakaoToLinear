import Foundation

public struct AttachmentFailure: Codable, Equatable, Sendable {
  public let attachmentId: String
  public let reason: String

  public init(attachmentId: String, reason: String) {
    self.attachmentId = attachmentId
    self.reason = reason
  }
}

public struct SourceBundle: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public let room: KakaoRoom
  public let messages: [KakaoMessage]
  public let resolvedAttachments: [ResolvedAttachment]
  public let attachmentFailures: [AttachmentFailure]
  public let createdAt: Date

  public init(
    id: String,
    room: KakaoRoom,
    messages: [KakaoMessage],
    resolvedAttachments: [ResolvedAttachment],
    attachmentFailures: [AttachmentFailure] = [],
    createdAt: Date = Date()
  ) {
    self.id = id
    self.room = room
    self.messages = messages
    self.resolvedAttachments = resolvedAttachments
    self.attachmentFailures = attachmentFailures
    self.createdAt = createdAt.millisecondPrecision
  }
}

public struct SourceCreateResult: Codable, Equatable, Sendable {
  public let sourceId: String
  public let messageCount: Int
  public let attachmentCount: Int
  public let attachmentFailureCount: Int

  public init(source: SourceBundle) {
    sourceId = source.id
    messageCount = source.messages.count
    attachmentCount = source.resolvedAttachments.count
    attachmentFailureCount = source.attachmentFailures.count
  }
}

public struct IssueDraft: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public let sourceId: String
  public let revision: Int
  public let parentDraftId: String?
  public var title: String
  public var summary: String
  public var requirements: [String]
  public var acceptanceCriteria: [String]
  public var notes: [String]
  public var questions: [String]
  public var sourceMessageIds: [String]
  public let createdAt: Date

  public init(
    id: String,
    sourceId: String,
    revision: Int = 1,
    parentDraftId: String? = nil,
    title: String,
    summary: String,
    requirements: [String],
    acceptanceCriteria: [String],
    notes: [String] = [],
    questions: [String] = [],
    sourceMessageIds: [String],
    createdAt: Date = Date()
  ) {
    self.id = id
    self.sourceId = sourceId
    self.revision = revision
    self.parentDraftId = parentDraftId
    self.title = title
    self.summary = summary
    self.requirements = requirements
    self.acceptanceCriteria = acceptanceCriteria
    self.notes = notes
    self.questions = questions
    self.sourceMessageIds = sourceMessageIds
    self.createdAt = createdAt.millisecondPrecision
  }
}

// MARK: - Evidence Analysis (2-pass PASS 1 결과)

public enum EvidenceSource: String, Codable, Sendable {
  case fact
  case request
  case constraint
  case condition
  case exclusion
  case ambiguity
  case relationship
}

/// 개별 evidence 항목. SourceBundle 내 source ID와 attachment ID로 추적 가능하게 연결한다.
public struct EvidenceItem: Codable, Equatable, Sendable {
  public let id: String
  public let source: EvidenceSource
  public let content: String
  public let sourceMessageIds: [String]
  public let attachmentIds: [String]
  public let confidence: Double
  public let kind: String?
  public let name: String?

  public init(
    id: String,
    source: EvidenceSource,
    content: String,
    sourceMessageIds: [String],
    attachmentIds: [String] = [],
    confidence: Double = 1.0,
    kind: String? = nil,
    name: String? = nil
  ) {
    self.id = id
    self.source = source
    self.content = content
    self.sourceMessageIds = sourceMessageIds
    self.attachmentIds = attachmentIds
    self.confidence = confidence
    self.kind = kind
    self.name = name
  }
}

public struct AttachmentInsight: Codable, Equatable, Sendable {
  public let attachmentId: String
  public let type: String  // "image" | "document" | "other"
  public let observations: [String]
  public let relatedMessageIds: [String]
  public let relatedRequests: [String]
  public let ambiguities: [String]
  public let confidence: Double

  public init(
    attachmentId: String,
    type: String,
    observations: [String],
    relatedMessageIds: [String] = [],
    relatedRequests: [String] = [],
    ambiguities: [String] = [],
    confidence: Double = 1.0
  ) {
    self.attachmentId = attachmentId
    self.type = type
    self.observations = observations
    self.relatedMessageIds = relatedMessageIds
    self.relatedRequests = relatedRequests
    self.ambiguities = ambiguities
    self.confidence = confidence
  }
}

public struct EvidenceAnalysis: Codable, Equatable, Sendable {
  public let id: String
  public let sourceId: String
  public let sourceHash: String
  public let facts: [EvidenceItem]
  public let requests: [EvidenceItem]
  public let constraints: [EvidenceItem]
  public let conditions: [EvidenceItem]
  public let exclusions: [EvidenceItem]
  public let ambiguities: [EvidenceItem]
  public let relationships: [EvidenceItem]
  public let attachmentInsights: [AttachmentInsight]
  public let overallConfidence: Double?
  public let createdAt: Date

  public init(
    id: String,
    sourceId: String,
    sourceHash: String,
    facts: [EvidenceItem],
    requests: [EvidenceItem],
    constraints: [EvidenceItem],
    conditions: [EvidenceItem],
    exclusions: [EvidenceItem],
    ambiguities: [EvidenceItem],
    relationships: [EvidenceItem],
    attachmentInsights: [AttachmentInsight],
    overallConfidence: Double?,
    createdAt: Date = Date()
  ) {
    self.id = id
    self.sourceId = sourceId
    self.sourceHash = sourceHash
    self.facts = facts
    self.requests = requests
    self.constraints = constraints
    self.conditions = conditions
    self.exclusions = exclusions
    self.ambiguities = ambiguities
    self.relationships = relationships
    self.attachmentInsights = attachmentInsights
    self.overallConfidence = overallConfidence
    self.createdAt = createdAt.millisecondPrecision
  }

  public var allItems: [EvidenceItem] {
    facts + requests + constraints + conditions + exclusions + ambiguities + relationships
  }
}

public enum AIProviderKind: String, Codable, CaseIterable, Identifiable, Sendable {
  case codexSubscription = "codex-subscription"
  case alibabaTokenPlan = "alibaba-token-plan"
  case openCodeFree = "opencode-free"
  case liteLLM = "litellm"
  case openAICompatible = "openai-compatible"

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .codexSubscription: "GPT · ChatGPT/Codex Plan"
    case .alibabaTokenPlan: "Alibaba Token Plan"
    case .openCodeFree: "OpenCode Free"
    case .liteLLM: "LiteLLM"
    case .openAICompatible: "OpenAI-compatible API"
    }
  }

  public var suggestedModel: String {
    switch self {
    case .codexSubscription: ""
    case .alibabaTokenPlan: "qwen3.6-flash"
    case .openCodeFree: "zen/big-pickle"
    case .liteLLM: ""
    case .openAICompatible: "gpt-4.1-mini"
    }
  }

  public var setupHint: String {
    switch self {
    case .codexSubscription: "codex login"
    case .alibabaTokenPlan, .openCodeFree, .liteLLM: "kakao-linear auth ai"
    case .openAICompatible: "kakao-linear auth ai"
    }
  }

  public var suggestedBaseURL: String {
    switch self {
    case .codexSubscription: ""
    case .alibabaTokenPlan:
      "https://token-plan.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1"
    case .openCodeFree: "https://opencode.ai/zen/v1"
    case .liteLLM: "http://localhost:4000/v1"
    case .openAICompatible: "https://api.openai.com/v1"
    }
  }
}

public struct AppConfiguration: Codable, Equatable, Sendable {
  public struct AI: Codable, Equatable, Sendable {
    public var provider: AIProviderKind
    public var baseURL: String
    public var model: String
    public var visionModel: String?
    public var commandPath: String?

    public init(
      provider: AIProviderKind = .codexSubscription,
      baseURL: String = "https://api.openai.com/v1",
      model: String = "",
      visionModel: String? = nil,
      commandPath: String? = nil
    ) {
      self.provider = provider
      self.baseURL = baseURL
      self.model = model
      self.visionModel = visionModel
      self.commandPath = commandPath
    }

    private enum CodingKeys: String, CodingKey {
      case provider
      case baseURL
      case model
      case visionModel
      case commandPath
    }

    public init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      provider =
        try container.decodeIfPresent(AIProviderKind.self, forKey: .provider)
        ?? .openAICompatible
      baseURL =
        try container.decodeIfPresent(String.self, forKey: .baseURL)
        ?? "https://api.openai.com/v1"
      model =
        try container.decodeIfPresent(String.self, forKey: .model)
        ?? provider.suggestedModel
      visionModel = try container.decodeIfPresent(String.self, forKey: .visionModel)
      commandPath = try container.decodeIfPresent(String.self, forKey: .commandPath)
    }
  }

  public struct Linear: Codable, Equatable, Sendable {
    public var endpoint: String
    public var defaultTeam: String?
    public var agentsMd: String?

    public init(endpoint: String = "https://api.linear.app/graphql", defaultTeam: String? = nil, agentsMd: String? = nil) {
      self.endpoint = endpoint
      self.defaultTeam = defaultTeam
      self.agentsMd = agentsMd
    }
  }

  public struct Hotkey: Codable, Equatable, Sendable {
    public var keyCode: UInt32
    public var modifiers: UInt32

    public init(keyCode: UInt32 = 37, modifiers: UInt32 = 2_304) {
      self.keyCode = keyCode
      self.modifiers = modifiers
    }
  }

  public var ai: AI
  public var linear: Linear
  public var hotkey: Hotkey

  public init(ai: AI = AI(), linear: Linear = Linear(), hotkey: Hotkey = Hotkey()) {
    self.ai = ai
    self.linear = linear
    self.hotkey = hotkey
  }
}

public struct LinearTeam: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public let key: String
  public let name: String

  public init(id: String, key: String, name: String) {
    self.id = id
    self.key = key
    self.name = name
  }
}

public struct LinearProject: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public let name: String

  public init(id: String, name: String) {
    self.id = id
    self.name = name
  }
}

public struct LinearStatus: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public let name: String
  public let type: String

  public init(id: String, name: String, type: String) {
    self.id = id
    self.name = name
    self.type = type
  }
}

public struct LinearMember: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public let name: String
  public let email: String?

  public init(id: String, name: String, email: String? = nil) {
    self.id = id
    self.name = name
    self.email = email
  }
}

public struct LinearLabel: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public let name: String
  public let color: String?

  public init(id: String, name: String, color: String? = nil) {
    self.id = id
    self.name = name
    self.color = color
  }
}

public enum LinearPriority: String, Codable, CaseIterable, Sendable {
  case none
  case urgent
  case high
  case medium
  case low

  public var apiValue: Int {
    switch self {
    case .none: 0
    case .urgent: 1
    case .high: 2
    case .medium: 3
    case .low: 4
    }
  }
}

public struct LinearIssueOptions: Codable, Equatable, Sendable {
  public var teamId: String
  public var projectId: String?
  public var statusId: String?
  public var assigneeId: String?
  public var priority: LinearPriority
  public var labelIds: [String]

  public init(
    teamId: String,
    projectId: String? = nil,
    statusId: String? = nil,
    assigneeId: String? = nil,
    priority: LinearPriority = .none,
    labelIds: [String] = []
  ) {
    self.teamId = teamId
    self.projectId = projectId
    self.statusId = statusId
    self.assigneeId = assigneeId
    self.priority = priority
    self.labelIds = labelIds
  }
}

public struct LinearIssueResult: Codable, Equatable, Sendable {
  public let id: String
  public let identifier: String
  public let url: URL
  public let title: String

  public init(id: String, identifier: String, url: URL, title: String) {
    self.id = id
    self.identifier = identifier
    self.url = url
    self.title = title
  }
}

public struct LinearDryRun: Codable, Equatable, Sendable {
  public let draftId: String
  public let title: String
  public let description: String
  public let options: LinearIssueOptions
  public let attachmentNames: [String]

  public init(
    draftId: String,
    title: String,
    description: String,
    options: LinearIssueOptions,
    attachmentNames: [String]
  ) {
    self.draftId = draftId
    self.title = title
    self.description = description
    self.options = options
    self.attachmentNames = attachmentNames
  }
}

public struct RoomLinearDefaults: Codable, Equatable, Sendable {
  public let roomId: String
  public var options: LinearIssueOptions

  public init(roomId: String, options: LinearIssueOptions) {
    self.roomId = roomId
    self.options = options
  }
}

public struct RoomFavoriteUpdate: Codable, Equatable, Sendable {
  public let roomId: String
  public let isFavorite: Bool

  public init(roomId: String, isFavorite: Bool) {
    self.roomId = roomId
    self.isFavorite = isFavorite
  }
}

private extension Date {
  var millisecondPrecision: Date {
    Date(timeIntervalSince1970: (timeIntervalSince1970 * 1_000).rounded() / 1_000)
  }
}
