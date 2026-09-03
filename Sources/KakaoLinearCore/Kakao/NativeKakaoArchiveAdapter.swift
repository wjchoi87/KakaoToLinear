import Foundation

public final class NativeKakaoArchiveAdapter: KakaoArchiveAdapter, @unchecked Sendable {
  private struct RawMessage {
    let chatId: Int64
    let logId: Int64
    let authorId: Int64
    let messageType: Int64
    let text: String?
    let sentAt: Double
    let attachment: String?
    let supplement: String?
  }

  private let authResolver: KakaoAuthResolver
  private let metadataParser = AttachmentMetadataParser()

  public convenience init() {
    self.init(paths: KakaoPaths())
  }

  init(paths: KakaoPaths) {
    authResolver = KakaoAuthResolver(paths: paths)
  }

  public func listRooms(limit: Int, query: String?) throws -> [KakaoRoom] {
    guard (1...1_000).contains(limit) else {
      throw KakaoLinearError.invalidInput("limit은 1~1000 범위여야 합니다.")
    }
    let (database, _) = try openDatabase()
    let users = try loadUsers(database)
    let customTitles = loadCustomTitles(database)
    let latestMessages = try loadLatestMessages(database)

    let statement = try database.prepare(
      "SELECT chatId, type, chatName, directChatMemberUserId FROM NTChatRoom"
    )
    var rooms: [KakaoRoom] = []
    while try statement.step() {
      let chatId = statement.int64(0)
      let directMemberId = statement.int64(3)
      let directName = users[directMemberId]
      let fallback = directName ?? "채팅방 \(chatId)"
      let title = customTitles[chatId] ?? statement.string(2).flatMap(nonEmpty) ?? fallback
      let participants = directName.map { [$0] } ?? []
      let latest = latestMessages[chatId]
      rooms.append(
        KakaoRoom(
          id: KakaoIdentifiers.room(chatId),
          title: title,
          lastMessage: latest?.text,
          lastActivityAt: latest.map { Date(timeIntervalSince1970: $0.sentAt) },
          participantNames: participants
        ))
    }

    if let query, !query.isEmpty {
      rooms = rooms.filter { room in
        room.title.localizedCaseInsensitiveContains(query)
          || room.participantNames.contains { $0.localizedCaseInsensitiveContains(query) }
      }
    }
    return rooms.sorted {
      ($0.lastActivityAt ?? .distantPast) > ($1.lastActivityAt ?? .distantPast)
    }.prefix(limit).map(\.self)
  }

  public func currentRoom() throws -> KakaoRoom? {
    guard let title = try KakaoAXAdapter().focusedRoomTitle() else { return nil }
    let rooms = try listRooms(limit: 1_000, query: nil)
    return rooms.first { room in
      room.title == title || title.localizedCaseInsensitiveContains(room.title)
    }
  }

  public func listMessages(
    roomId: String,
    beforeMessageId: String?,
    limit: Int
  ) throws -> [KakaoMessage] {
    guard (1...1_000).contains(limit) else {
      throw KakaoLinearError.invalidInput("limit은 1~1000 범위여야 합니다.")
    }
    let chatId = try KakaoIdentifiers.chatId(from: roomId)
    let before = try beforeMessageId.map(KakaoIdentifiers.logId)
    let (database, auth) = try openDatabase()
    let users = try loadUsers(database)

    var sql = """
      SELECT chatId, logId, authorId, type, message, sentAt, attachment, supplement
      FROM NTChatMessage
      WHERE chatId = ?
      """
    var bindings: [SQLCipherDatabase.Binding] = [.int64(chatId)]
    if let before {
      sql += " AND logId < ?"
      bindings.append(.int64(before))
    }
    sql += " ORDER BY logId DESC LIMIT ?"
    bindings.append(.int64(Int64(limit)))

    let statement = try database.prepare(sql, bindings: bindings)
    var rows: [RawMessage] = []
    while try statement.step() {
      rows.append(rawMessage(statement))
    }
    guard !rows.isEmpty || roomExists(chatId: chatId, database: database) else {
      throw KakaoLinearError.roomNotFound(roomId)
    }
    return rows.reversed().map { mapMessage($0, currentUserId: auth.userId, users: users) }
  }

  public func resolveAttachment(id: String, outputDirectory: URL) async throws -> ResolvedAttachment
  {
    let parts = try KakaoIdentifiers.attachmentParts(from: id)
    let (database, _) = try openDatabase()
    let row = try loadMessage(logId: parts.logId, database: database)
    let attachments = metadataParser.parse(
      logId: row.logId,
      messageType: row.messageType,
      rawJSON: row.attachment
    )
    guard let attachment = attachments.first(where: { $0.id == id }) else {
      throw KakaoLinearError.messageNotFound(id)
    }

    let resolver = FullAttachmentResolver(container: authResolver.paths.container)
    return try await resolver.resolve(
      attachment: attachment,
      chatId: row.chatId,
      logId: row.logId,
      messageType: row.messageType,
      frameIndex: parts.index,
      outputDirectory: outputDirectory
    )
  }

  public func databaseIsReadable() -> Bool {
    (try? openDatabase(allowRecovery: false)) != nil
  }

  private func openDatabase(
    allowRecovery: Bool = true
  ) throws -> (SQLCipherDatabase, ResolvedKakaoAuth) {
    let auth = try authResolver.resolve(allowRecovery: allowRecovery)
    let key = try KakaoKeyDerivation.secureKey(userId: auth.userId, uuid: auth.uuid)
    return (try SQLCipherDatabase(url: auth.databaseURL, key: key), auth)
  }

  private func loadUsers(_ database: SQLCipherDatabase) throws -> [Int64: String] {
    let statement = try database.prepare(
      "SELECT userId, friendNickName, displayName, nickName FROM NTUser"
    )
    var users: [Int64: String] = [:]
    while try statement.step() {
      let userId = statement.int64(0)
      let name =
        statement.string(1).flatMap(nonEmpty)
        ?? statement.string(2).flatMap(nonEmpty)
        ?? statement.string(3).flatMap(nonEmpty)
      if let name, users[userId] == nil { users[userId] = name }
    }
    return users
  }

  private func loadCustomTitles(_ database: SQLCipherDatabase) -> [Int64: String] {
    guard
      let statement = try? database.prepare(
        """
        SELECT chatId, content FROM NTChatMeta
        WHERE type = 3 AND content IS NOT NULL AND content <> ''
        ORDER BY revision ASC
        """
      )
    else { return [:] }
    var titles: [Int64: String] = [:]
    while (try? statement.step()) == true {
      if let title = statement.string(1).flatMap(nonEmpty) {
        titles[statement.int64(0)] = title
      }
    }
    return titles
  }

  private func loadLatestMessages(_ database: SQLCipherDatabase) throws -> [Int64: (
    text: String?, sentAt: Double
  )] {
    let statement = try database.prepare(
      """
      SELECT message.chatId, message.message, message.sentAt
      FROM NTChatMessage AS message
      INNER JOIN (
          SELECT chatId, MAX(logId) AS logId
          FROM NTChatMessage
          GROUP BY chatId
      ) AS latest
      ON latest.chatId = message.chatId AND latest.logId = message.logId
      """
    )
    var messages: [Int64: (text: String?, sentAt: Double)] = [:]
    while try statement.step() {
      messages[statement.int64(0)] = (statement.string(1), statement.double(2))
    }
    return messages
  }

  private func roomExists(chatId: Int64, database: SQLCipherDatabase) -> Bool {
    guard
      let statement = try? database.prepare(
        "SELECT 1 FROM NTChatRoom WHERE chatId = ? LIMIT 1",
        bindings: [.int64(chatId)]
      )
    else { return false }
    return (try? statement.step()) == true
  }

  private func loadMessage(logId: Int64, database: SQLCipherDatabase) throws -> RawMessage {
    let statement = try database.prepare(
      """
      SELECT chatId, logId, authorId, type, message, sentAt, attachment, supplement
      FROM NTChatMessage WHERE logId = ? LIMIT 1
      """,
      bindings: [.int64(logId)]
    )
    guard try statement.step() else {
      throw KakaoLinearError.messageNotFound(KakaoIdentifiers.message(logId))
    }
    return rawMessage(statement)
  }

  private func rawMessage(_ statement: SQLCipherDatabase.Statement) -> RawMessage {
    RawMessage(
      chatId: statement.int64(0),
      logId: statement.int64(1),
      authorId: statement.int64(2),
      messageType: statement.int64(3),
      text: statement.string(4).flatMap(nonEmpty),
      sentAt: statement.double(5),
      attachment: statement.string(6),
      supplement: statement.string(7)
    )
  }

  private func mapMessage(
    _ row: RawMessage,
    currentUserId: Int64,
    users: [Int64: String]
  ) -> KakaoMessage {
    let messageId = KakaoIdentifiers.message(row.logId)
    let isMine = row.authorId == currentUserId
    // 답장 인용 원문과 대상 작성자를 attachment/supplement JSON에서 추출한다.
    let quote = replyQuote(from: row.attachment) ?? replyQuote(from: row.supplement)
    return KakaoMessage(
      id: messageId,
      roomId: KakaoIdentifiers.room(row.chatId),
      senderId: String(row.authorId),
      senderName: isMine ? "나" : (users[row.authorId] ?? "사용자 \(row.authorId)"),
      timestamp: Date(timeIntervalSince1970: row.sentAt),
      type: mapType(row.messageType),
      text: row.text,
      attachments: metadataParser.parse(
        logId: row.logId,
        messageType: row.messageType,
        rawJSON: row.attachment
      ),
      replyToMessageId: replyMessageId(row.attachment) ?? replyMessageId(row.supplement),
      isMine: isMine,
      replyQuoteText: quote?.text,
      replyAuthorName: quoteAuthorName(from: quote, users: users)
    )
  }

  private func quoteAuthorName(
    from quote: (text: String, authorId: Int64?, rawAuthorName: String?)?,
    users: [Int64: String]
  ) -> String? {
    guard let quote else { return nil }
    if let authorId = quote.authorId, let name = users[authorId] { return name }
    return quote.rawAuthorName
  }

  // 답장 rawJSON에서 인용 원문(reply.src_message.content)과 대상 작성자를 추출한다.
  // Kakao 답장 메시지 attachment 형식: { "reply": { "src_logId":…, "src_userId":…,
  //   "src_message": { "content": "인용 원문", "chatId":…, … } } }
  func replyQuote(from rawJSON: String?) -> (
    text: String, authorId: Int64?, rawAuthorName: String?
  )? {
    guard let rawJSON,
      let data = rawJSON.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    let containers = ["reply", "src", "origin", "parent"]
    for container in containers {
      guard let reply = object[container] as? [String: Any] else { continue }
      var authorId = coerceInt64(reply["src_userId"] ?? reply["srcUserId"])
      var rawName = reply["src_userNickName"] as? String ?? reply["srcUserNickName"] as? String
      var content: String?
      if let srcMessage = (reply["src_message"] ?? reply["srcMessage"]) as? [String: Any] {
        content =
          srcMessage["content"] as? String
          ?? srcMessage["message"] as? String
          ?? srcMessage["text"] as? String
        if authorId == nil { authorId = coerceInt64(srcMessage["userId"]) }
        if rawName == nil { rawName = srcMessage["nickName"] as? String }
      }
      if content == nil {
        content =
          coerceString(reply["src_message_content"])
          ?? coerceString(reply["srcMessageContent"])
          ?? coerceString(reply["message"])
      }
      if let content, !content.isEmpty {
        return (content.trimmingCharacters(in: .whitespacesAndNewlines), authorId, rawName)
      }
    }
    return nil
  }

  private func replyMessageId(_ rawJSON: String?) -> String? {
    guard let rawJSON,
      let data = rawJSON.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    let keys = ["src_logId", "srcLogId", "parentLogId", "src_log_id"]
    let containers = ["reply", "src", "origin", "parent"]
    for container in containers {
      if let nested = object[container] as? [String: Any],
        let id = keys.compactMap({ coerceInt64(nested[$0]) }).first(where: { $0 > 0 })
      {
        return KakaoIdentifiers.message(id)
      }
    }
    if let id = keys.compactMap({ coerceInt64(object[$0]) }).first(where: { $0 > 0 }) {
      return KakaoIdentifiers.message(id)
    }
    return nil
  }

  private func coerceInt64(_ value: Any?) -> Int64? {
    if let number = value as? NSNumber { return number.int64Value }
    if let string = value as? String { return Int64(string) }
    return nil
  }

  private func coerceString(_ value: Any?) -> String? {
    if let string = value as? String, !string.isEmpty { return string }
    return nil
  }

  private func mapType(_ raw: Int64) -> MessageType {
    switch raw {
    case 1: .text
    case 2: .image
    case 3: .video
    case 18: .file
    case 27: .album
    case 0: .system
    default: .unknown
    }
  }

  private func nonEmpty(_ value: String) -> String? {
    value.isEmpty ? nil : value
  }
}
