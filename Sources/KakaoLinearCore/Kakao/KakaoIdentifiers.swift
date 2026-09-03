import Foundation

enum KakaoIdentifiers {
  static func room(_ chatId: Int64) -> String { "room_\(chatId)" }
  static func message(_ logId: Int64) -> String { "msg_\(logId)" }
  static func attachment(_ logId: Int64, index: Int) -> String { "att_\(logId)_\(index)" }

  static func chatId(from roomId: String) throws -> Int64 {
    try parseInt64(roomId, prefix: "room_", label: "room id")
  }

  static func logId(from messageId: String) throws -> Int64 {
    try parseInt64(messageId, prefix: "msg_", label: "message id")
  }

  static func attachmentParts(from attachmentId: String) throws -> (logId: Int64, index: Int) {
    guard attachmentId.hasPrefix("att_") else {
      throw KakaoLinearError.invalidInput("잘못된 attachment id입니다: \(attachmentId)")
    }
    let parts = attachmentId.dropFirst(4).split(separator: "_", omittingEmptySubsequences: false)
    guard parts.count == 2,
      let logId = Int64(parts[0]), logId > 0,
      let index = Int(parts[1]), index >= 0
    else {
      throw KakaoLinearError.invalidInput("잘못된 attachment id입니다: \(attachmentId)")
    }
    return (logId, index)
  }

  private static func parseInt64(_ value: String, prefix: String, label: String) throws -> Int64 {
    guard value.hasPrefix(prefix),
      let parsed = Int64(value.dropFirst(prefix.count)),
      parsed > 0
    else {
      throw KakaoLinearError.invalidInput("잘못된 \(label)입니다: \(value)")
    }
    return parsed
  }
}
