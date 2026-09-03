import Foundation

public struct KakaoRoom: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public let title: String
  public let lastMessage: String?
  public let lastActivityAt: Date?
  public let participantNames: [String]

  public init(
    id: String,
    title: String,
    lastMessage: String? = nil,
    lastActivityAt: Date? = nil,
    participantNames: [String] = []
  ) {
    self.id = id
    self.title = title
    self.lastMessage = lastMessage
    self.lastActivityAt = lastActivityAt
    self.participantNames = participantNames
  }
}

public enum MessageType: String, Codable, Sendable {
  case text
  case image
  case album
  case file
  case video
  case system
  case unknown
}

public enum AttachmentKind: String, Codable, Sendable {
  case image
  case file
  case video
  case unknown
}

public struct KakaoAttachment: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public let messageId: String
  public let kind: AttachmentKind
  public let originalName: String?
  public let mimeType: String?
  public let byteSize: Int64?
  public let localFullPath: URL?
  public let localThumbnailPath: URL?
  public let remoteURL: URL?
  public let hash: String?
  public let fullAvailable: Bool

  public init(
    id: String,
    messageId: String,
    kind: AttachmentKind,
    originalName: String? = nil,
    mimeType: String? = nil,
    byteSize: Int64? = nil,
    localFullPath: URL? = nil,
    localThumbnailPath: URL? = nil,
    remoteURL: URL? = nil,
    hash: String? = nil,
    fullAvailable: Bool = false
  ) {
    self.id = id
    self.messageId = messageId
    self.kind = kind
    self.originalName = originalName
    self.mimeType = mimeType
    self.byteSize = byteSize
    self.localFullPath = localFullPath
    self.localThumbnailPath = localThumbnailPath
    self.remoteURL = remoteURL
    self.hash = hash
    self.fullAvailable = fullAvailable
  }
}

public struct KakaoMessage: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public let roomId: String
  public let senderId: String?
  public let senderName: String
  public let timestamp: Date
  public let type: MessageType
  public let text: String?
  public let attachments: [KakaoAttachment]
  public let replyToMessageId: String?
  /// 현재 사용자가 보낸 메시지 여부. senderName 문자열 비교 대신 이 값을 사용한다.
  public let isMine: Bool
  /// 답장 메시지에 담긴 인용 원문(reply.src_message.content). 로드된 본문 text와 다를 수 있다.
  public let replyQuoteText: String?
  /// 답장 대상(원본) 메시지 작성자 이름. 없으면 senderName 대신 placeholder를 쓴다.
  public let replyAuthorName: String?

  public init(
    id: String,
    roomId: String,
    senderId: String? = nil,
    senderName: String,
    timestamp: Date,
    type: MessageType,
    text: String? = nil,
    attachments: [KakaoAttachment] = [],
    replyToMessageId: String? = nil,
    isMine: Bool = false,
    replyQuoteText: String? = nil,
    replyAuthorName: String? = nil
  ) {
    self.id = id
    self.roomId = roomId
    self.senderId = senderId
    self.senderName = senderName
    self.timestamp = timestamp
    self.type = type
    self.text = text
    self.attachments = attachments
    self.replyToMessageId = replyToMessageId
    self.isMine = isMine
    self.replyQuoteText = replyQuoteText
    self.replyAuthorName = replyAuthorName
  }

  // 변경 전 정책 - 모든 필수 필드만 Codable로 합성하고 새 필드가 없으면 저장된 source를 못 읽었다.
  // 변경 후 정책 - isMine/replyQuoteText/replyAuthorName은 optional 기본값으로 디코딩해 구형 source와 호환한다.
  // 변경 이유 - 이미 영속화된 SourceBundle JSON을 유지하면서 탐색·답장 UI에 필요한 새 필드를 추가하기 위해서다.
  // 영향 범위 - KakaoMessage를 저장/로드하는 source/prompt 전반. 새 필드가 없는 기존 JSON도 그대로 읽힌다.
  private enum CodingKeys: String, CodingKey {
    case id, roomId, senderId, senderName, timestamp, type, text, attachments,
      replyToMessageId, isMine, replyQuoteText, replyAuthorName
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(String.self, forKey: .id)
    roomId = try c.decode(String.self, forKey: .roomId)
    senderId = try c.decodeIfPresent(String.self, forKey: .senderId)
    senderName = try c.decode(String.self, forKey: .senderName)
    timestamp = try c.decode(Date.self, forKey: .timestamp)
    type = try c.decode(MessageType.self, forKey: .type)
    text = try c.decodeIfPresent(String.self, forKey: .text)
    attachments = (try c.decodeIfPresent([KakaoAttachment].self, forKey: .attachments)) ?? []
    replyToMessageId = try c.decodeIfPresent(String.self, forKey: .replyToMessageId)
    isMine = (try? c.decodeIfPresent(Bool.self, forKey: .isMine)) ?? false
    replyQuoteText = try c.decodeIfPresent(String.self, forKey: .replyQuoteText)
    replyAuthorName = try c.decodeIfPresent(String.self, forKey: .replyAuthorName)
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(id, forKey: .id)
    try c.encode(roomId, forKey: .roomId)
    try c.encodeIfPresent(senderId, forKey: .senderId)
    try c.encode(senderName, forKey: .senderName)
    try c.encode(timestamp, forKey: .timestamp)
    try c.encode(type, forKey: .type)
    try c.encodeIfPresent(text, forKey: .text)
    try c.encode(attachments, forKey: .attachments)
    try c.encodeIfPresent(replyToMessageId, forKey: .replyToMessageId)
    try c.encode(isMine, forKey: .isMine)
    try c.encodeIfPresent(replyQuoteText, forKey: .replyQuoteText)
    try c.encodeIfPresent(replyAuthorName, forKey: .replyAuthorName)
  }
}

public struct ResolvedAttachment: Codable, Equatable, Sendable {
  public enum Tier: String, Codable, Sendable {
    case localFull
    case cdn
  }

  public let attachment: KakaoAttachment
  public let fileURL: URL
  public let tier: Tier
  public let sha1: String

  public init(attachment: KakaoAttachment, fileURL: URL, tier: Tier, sha1: String) {
    self.attachment = attachment
    self.fileURL = fileURL
    self.tier = tier
    self.sha1 = sha1
  }
}

public struct DoctorReport: Codable, Equatable, Sendable {
  public let kakaoRunning: Bool
  public let accessibility: Bool
  public let fullDiskAccess: Bool
  public let kakaoDatabase: Bool
  public let linear: Bool
  public let ai: Bool

  public init(
    kakaoRunning: Bool,
    accessibility: Bool,
    fullDiskAccess: Bool,
    kakaoDatabase: Bool,
    linear: Bool = false,
    ai: Bool = false
  ) {
    self.kakaoRunning = kakaoRunning
    self.accessibility = accessibility
    self.fullDiskAccess = fullDiskAccess
    self.kakaoDatabase = kakaoDatabase
    self.linear = linear
    self.ai = ai
  }
}

public struct APIEnvelope<Value: Codable & Sendable>: Codable, Sendable {
  public let schemaVersion: Int
  public let data: Value

  public init(schemaVersion: Int = 1, data: Value) {
    self.schemaVersion = schemaVersion
    self.data = data
  }
}

/*
 변경 전 정책 - IssueComposer(agentsMd): promptBuilder에서 agentsMd를 미리 결합해두면 AI 응답이 길어짐.
 변경 후 정책 - IssueComposer에서 agentsMd를 프롬프트 최상단에 "SYSTEM CONTEXT"로 포함하되, 분량을 제한한다.
 변경 이유 - 사용자가 편집한 AGENTS.md가 AI 프롬프트에 반영되어야 한다.
 영향 범위 - composeIssue / reviseIssue 모든 호출 경로. agentsMd가 없으면 기존과 동일하게 동작.
 */
