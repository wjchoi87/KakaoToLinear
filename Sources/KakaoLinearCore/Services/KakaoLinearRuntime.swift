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

  public func aiProvider() async throws -> any AIProvider {
    let config = try await configuration.load()
    switch config.ai.provider {
    case .codexSubscription:
      return CodexCLIProvider(commandPath: config.ai.commandPath, model: config.ai.model)
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
    case .codexSubscription: nil
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
