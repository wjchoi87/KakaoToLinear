import Foundation

public struct AIProviderInfo: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public let name: String
  public let setupHint: String
  public let supportsImages: Bool

  public init(kind: AIProviderKind) {
    id = kind.rawValue
    name = kind.displayName
    setupHint = kind.setupHint
    supportsImages = kind != .openCodeFree
  }
}

public struct AIModelInfo: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public let name: String

  public init(id: String, name: String) {
    self.id = id
    self.name = name
  }
}

public struct AIProviderCatalog: Sendable {
  private let session: URLSession

  public init(session: URLSession = .shared) {
    self.session = session
  }

  public func providers() -> [AIProviderInfo] {
    AIProviderKind.allCases.map(AIProviderInfo.init)
  }

  public func models(
    provider: AIProviderKind,
    baseURL: String,
    apiKey: String?,
    configuredModel: String = ""
  ) async throws -> [AIModelInfo] {
    switch provider {
    case .codexSubscription:
      return configuredModel.isEmpty
        ? [AIModelInfo(id: "", name: "Codex CLI 기본 모델")]
        : [AIModelInfo(id: configuredModel, name: configuredModel)]
    case .openCodeFree:
      guard let apiKey, !apiKey.isEmpty else {
        throw KakaoLinearError.permission("OpenCode API key가 없습니다. kakao-linear auth ai를 실행해주세요.")
      }
      return try await OpenCodeFreeCatalog(session: session).models(apiKey: apiKey)
    case .alibabaTokenPlan:
      guard let apiKey, !apiKey.isEmpty else {
        throw KakaoLinearError.permission(
          "Alibaba Token Plan key가 없습니다. API key를 입력한 뒤 모델 새로고침을 누르세요."
        )
      }
      return try await openAIModels(baseURL: baseURL, apiKey: apiKey)
    case .liteLLM, .openAICompatible:
      return try await openAIModels(baseURL: baseURL, apiKey: apiKey)
    }
  }

  private func openAIModels(baseURL: String, apiKey: String?) async throws -> [AIModelInfo] {
    guard let base = URL(string: baseURL),
      ["http", "https"].contains(base.scheme?.lowercased())
    else {
      throw KakaoLinearError.invalidInput("AI provider base URL이 올바르지 않습니다.")
    }
    var request = URLRequest(url: base.appending(path: "models"))
    request.timeoutInterval = 15
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if let apiKey, !apiKey.isEmpty {
      request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    }
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      throw KakaoLinearError.aiProvider("AI provider model catalog 요청에 실패했습니다.")
    }
    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let entries = root["data"] as? [[String: Any]]
    else {
      throw KakaoLinearError.aiProvider("AI provider model catalog 형식이 올바르지 않습니다.")
    }
    let models = entries.compactMap { entry -> AIModelInfo? in
      guard let id = entry["id"] as? String, !id.isEmpty else { return nil }
      return AIModelInfo(id: id, name: id)
    }.sorted { $0.id < $1.id }
    guard !models.isEmpty else {
      throw KakaoLinearError.aiProvider("AI provider가 사용 가능한 model을 반환하지 않았습니다.")
    }
    return models
  }
}
