import Foundation

public enum KakaoLinearError: Error, LocalizedError, Sendable {
  case permission(String)
  case kakaoNotRunning
  case roomNotFound(String)
  case messageNotFound(String)
  case attachmentResolution(String)
  case aiProvider(String)
  case linearAPI(String)
  case invalidInput(String)
  case alreadyCreated(String)
  case kakaoDatabase(String)
  case internalFailure(String)

  public var exitCode: Int32 {
    switch self {
    case .permission: 10
    case .kakaoNotRunning: 11
    case .roomNotFound: 12
    case .messageNotFound: 13
    case .attachmentResolution: 20
    case .aiProvider: 30
    case .linearAPI: 40
    case .invalidInput: 50
    case .alreadyCreated: 60
    case .kakaoDatabase, .internalFailure: 1
    }
  }

  public var errorDescription: String? {
    switch self {
    case .permission(let message),
      .attachmentResolution(let message),
      .aiProvider(let message),
      .linearAPI(let message),
      .invalidInput(let message),
      .alreadyCreated(let message),
      .kakaoDatabase(let message),
      .internalFailure(let message):
      message
    case .kakaoNotRunning:
      "카카오톡이 실행되고 있지 않습니다."
    case .roomNotFound(let id):
      "채팅방을 찾을 수 없습니다: \(id)"
    case .messageNotFound(let id):
      "메시지를 찾을 수 없습니다: \(id)"
    }
  }
}
