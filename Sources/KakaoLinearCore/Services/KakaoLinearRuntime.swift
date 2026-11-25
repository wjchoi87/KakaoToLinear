import Foundation

public struct KakaoLinearRuntime: Sendable {
  public let paths: AppSupportPaths
  public let artifacts: ArtifactStore
  public let configuration: ConfigurationStore
  public let roomDefaults: RoomDefaultsStore
  public let roomFavorites: RoomFavoritesStore
  public let secrets: KeychainSecretStore

  public init(paths: AppSupportPaths = AppSupportPaths()) {
    self.paths = paths
    artifacts = ArtifactStore(paths: paths)
    configuration = ConfigurationStore(paths: paths)
    roomDefaults = RoomDefaultsStore(paths: paths)
    roomFavorites = RoomFavoritesStore(paths: paths)
    secrets = KeychainSecretStore()
  }

  /*
   변경 전 정책 - provider override 시 model/baseURL/visionModel만 바꾸고 저장된 ai.commandPath는 그대로 썼다.
   변경 후 정책 - override provider가 저장된 provider와 다르면 이번 호출에서 ai.commandPath를 쓰지 않는다.
   변경 이유 - CLI provider가 Codex·Claude 두 개가 되어, 한쪽 CLI path override가 다른 CLI 실행 파일로 쓰일 수 있다.
   영향 범위 - `--provider`로 저장된 것과 다른 provider를 지정한 1회성 호출. 같은 provider면 기존과 동일하다.
   */
  /// provider/model을 지정하면 저장된 설정은 건드리지 않고 이번 호출에만 덮어쓴다.
  public func aiProvider(
    provider override: AIProviderKind? = nil, model: String? = nil
  ) async throws -> any AIProvider {
    var config = try await configuration.load()
    if let override {
      if override != config.ai.provider { config.ai.commandPath = nil }
      config.ai.provider = override
      config.ai.model = model ?? override.suggestedModel
      if !override.suggestedBaseURL.isEmpty { config.ai.baseURL = override.suggestedBaseURL }
      config.ai.visionModel = nil
    } else if let model {
      config.ai.model = model
      config.ai.visionModel = nil
    }
    switch config.ai.provider {
    case .codexSubscription:
      return CodexCLIProvider(commandPath: config.ai.commandPath, model: config.ai.model)
    case .claudeSubscription:
      return ClaudeCLIProvider(commandPath: config.ai.commandPath, model: config.ai.model)
    case .alibabaTokenPlan:
      guard let key = try secrets.get(.alibabaTokenPlanAPIKey), !key.isEmpty else {
        throw KakaoLinearError.permission(
          "Alibaba Token Plan key가 없습니다. kakao-linear auth ai를 실행해주세요."
        )
      }
      var providerConfig = config.ai
      providerConfig.visionModel = providerConfig.visionModel ?? providerConfig.model
      return OpenAICompatibleProvider(configuration: providerConfig, apiKey: key)
    case .openCodeFree:
      guard let key = try secrets.get(.openCodeAPIKey), !key.isEmpty else {
        throw KakaoLinearError.permission(
          "OpenCode API key가 없습니다. kakao-linear auth ai를 실행해주세요."
        )
      }
      return try OpenCodeFreeProvider(model: config.ai.model, apiKey: key)
    case .liteLLM:
      return OpenAICompatibleProvider(
        configuration: config.ai,
        apiKey: try secrets.get(.liteLLMAPIKey)
      )
    case .openAICompatible:
      let key = try secrets.get(.aiAPIKey)
      return OpenAICompatibleProvider(configuration: config.ai, apiKey: key)
    }
  }

  public func aiSecret(for provider: AIProviderKind) throws -> String? {
    switch provider {
    case .codexSubscription, .claudeSubscription: nil
    case .alibabaTokenPlan: try secrets.get(.alibabaTokenPlanAPIKey)
    case .openCodeFree: try secrets.get(.openCodeAPIKey)
    case .liteLLM: try secrets.get(.liteLLMAPIKey)
    case .openAICompatible: try secrets.get(.aiAPIKey)
    }
  }

  public func setAISecret(_ value: String, for provider: AIProviderKind) throws {
    let kind: SecretKind
    switch provider {
    case .codexSubscription:
      throw KakaoLinearError.invalidInput("Codex subscription credential은 Codex CLI가 소유합니다.")
    case .claudeSubscription:
      throw KakaoLinearError.invalidInput("Claude subscription credential은 Claude Code CLI가 소유합니다.")
    case .alibabaTokenPlan: kind = .alibabaTokenPlanAPIKey
    case .openCodeFree: kind = .openCodeAPIKey
    case .liteLLM: kind = .liteLLMAPIKey
    case .openAICompatible: kind = .aiAPIKey
    }
    if value.isEmpty { try secrets.delete(kind) } else { try secrets.set(value, for: kind) }
  }

  public func linearClient() async throws -> LinearClient {
    let config = try await configuration.load()
    guard let endpoint = URL(string: config.linear.endpoint), endpoint.scheme == "https" else {
      throw KakaoLinearError.invalidInput("Linear endpoint가 올바르지 않습니다.")
    }
    guard let key = try secrets.get(.linearAPIKey), !key.isEmpty else {
      throw KakaoLinearError.permission("Linear API key가 없습니다. kakao-linear auth linear을 실행해주세요.")
    }
    return LinearClient(endpoint: endpoint, apiKey: key)
  }
}
