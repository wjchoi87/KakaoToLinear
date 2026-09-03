import Foundation

public actor ConfigurationStore {
  private let paths: AppSupportPaths

  public init(paths: AppSupportPaths = AppSupportPaths()) {
    self.paths = paths
  }

  public func load() throws -> AppConfiguration {
    guard FileManager.default.fileExists(atPath: paths.config.path) else {
      return AppConfiguration()
    }
    do {
      return try JSONDecoder.kakaoLinear.decode(
        AppConfiguration.self,
        from: Data(contentsOf: paths.config)
      )
    } catch {
      throw KakaoLinearError.invalidInput("config.json을 읽을 수 없습니다.")
    }
  }

  public func save(_ config: AppConfiguration) throws {
    try paths.ensureDirectories()
    try JSONEncoder.kakaoLinear.encode(config).write(to: paths.config, options: .atomic)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600], ofItemAtPath: paths.config.path)
  }

  public func set(key: String, value: String) throws -> AppConfiguration {
    var config = try load()
    switch key {
    case "ai.provider":
      guard let provider = AIProviderKind(rawValue: value) else {
        throw KakaoLinearError.invalidInput(
          "ai.provider는 \(AIProviderKind.allCases.map(\.rawValue).joined(separator: ", ")) 중 하나여야 합니다."
        )
      }
      config.ai.provider = provider
      config.ai.model = provider.suggestedModel
      if !provider.suggestedBaseURL.isEmpty { config.ai.baseURL = provider.suggestedBaseURL }
    case "ai.base-url":
      guard let url = URL(string: value), url.scheme != nil else {
        throw KakaoLinearError.invalidInput("유효한 ai.base-url이 아닙니다.")
      }
      config.ai.baseURL = value
    case "ai.model":
      config.ai.model = value.trimmingCharacters(in: .whitespacesAndNewlines)
    case "ai.vision-model":
      config.ai.visionModel = value.isEmpty ? nil : value
    case "ai.command-path":
      config.ai.commandPath = value.isEmpty ? nil : value
    case "linear.endpoint":
      guard let url = URL(string: value), url.scheme == "https" else {
        throw KakaoLinearError.invalidInput("Linear endpoint는 HTTPS URL이어야 합니다.")
      }
      config.linear.endpoint = value
    case "linear.team":
      config.linear.defaultTeam = value.isEmpty ? nil : value
    case "linear.agentsMd":
      config.linear.agentsMd = value.isEmpty ? nil : value
    case "hotkey.key-code":
      guard let keyCode = UInt32(value) else {
        throw KakaoLinearError.invalidInput("hotkey.key-code는 UInt32여야 합니다.")
      }
      config.hotkey.keyCode = keyCode
    case "hotkey.modifiers":
      guard let modifiers = UInt32(value) else {
        throw KakaoLinearError.invalidInput("hotkey.modifiers는 UInt32여야 합니다.")
      }
      config.hotkey.modifiers = modifiers
    default:
      throw KakaoLinearError.invalidInput("지원하지 않는 config key입니다: \(key)")
    }
    try save(config)
    return config
  }
}
