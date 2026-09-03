import Foundation

public struct OpenCodeFreeProvider: AIProvider {
  private let delegate: OpenAICompatibleProvider
  private let catalog: OpenCodeFreeCatalog
  private let model: String
  private let apiKey: String

  public init(model: String, apiKey: String, session: URLSession = .shared) throws {
    guard let parsed = OpenCodeModelID(rawValue: model) else {
      throw KakaoLinearError.invalidInput("OpenCode Free model은 zen/<id> 또는 go/<id> 형식이어야 합니다.")
    }
    self.model = model
    self.apiKey = apiKey
    catalog = OpenCodeFreeCatalog(session: session)
    delegate = OpenAICompatibleProvider(
      configuration: AppConfiguration.AI(
        provider: .openCodeFree,
        baseURL: parsed.baseURL,
        model: parsed.upstreamId
      ),
      apiKey: apiKey,
      session: session
    )
  }

  public func analyzeEvidence(
    source: SourceBundle,
    agentsInstructions: String?
  ) async throws -> EvidenceAnalysis {
    try await ensureSelectedModelIsFree()
    return try await delegate.analyzeEvidence(
      source: source, agentsInstructions: agentsInstructions)
  }

  public func composeIssue(
    source: SourceBundle,
    evidence: EvidenceAnalysis,
    agentsInstructions: String?
  ) async throws -> IssueDraft {
    try await ensureSelectedModelIsFree()
    return try await delegate.composeIssue(
      source: source, evidence: evidence, agentsInstructions: agentsInstructions)
  }

  public func reviseIssue(
    source: SourceBundle,
    evidence: EvidenceAnalysis,
    current: IssueDraft,
    instruction: String,
    agentsInstructions: String?
  ) async throws -> IssueDraft {
    try await ensureSelectedModelIsFree()
    return try await delegate.reviseIssue(
      source: source, evidence: evidence, current: current, instruction: instruction,
      agentsInstructions: agentsInstructions)
  }

  public func healthCheck() async -> Bool {
    guard let models = try? await catalog.models(apiKey: apiKey) else { return false }
    return models.contains { $0.id == model }
  }

  private func ensureSelectedModelIsFree() async throws {
    let models = try await catalog.models(apiKey: apiKey)
    guard models.contains(where: { $0.id == model }) else {
      throw KakaoLinearError.aiProvider(
        "선택한 OpenCode model은 현재 FREE로 확인되지 않아 호출하지 않습니다: \(model)"
      )
    }
  }
}

struct OpenCodeModelID: Sendable {
  enum Source: String, Sendable { case zen; case go }
  let source: Source
  let upstreamId: String

  init?(rawValue: String) {
    let parts = rawValue.split(separator: "/", maxSplits: 1).map(String.init)
    guard parts.count == 2, let source = Source(rawValue: parts[0]), !parts[1].isEmpty else {
      return nil
    }
    self.source = source
    upstreamId = parts[1]
  }

  var baseURL: String {
    source == .zen ? "https://opencode.ai/zen/v1" : "https://opencode.ai/zen/go/v1"
  }
}

struct OpenCodeFreeCatalog: Sendable {
  private struct CatalogModel: Sendable {
    let source: OpenCodeModelID.Source
    let id: String
    let prices: [Double]
  }

  private let session: URLSession

  init(session: URLSession = .shared) {
    self.session = session
  }

  /*
   변경 전 정책 - OpenCode model을 외부 XAL process가 선별했다.
   변경 후 정책 - Zen/Go catalog를 직접 읽고 positive price는 제외하며 FREE 근거가 명확한 model만 노출한다.
   변경 이유 - xal-plugins를 참고 구현으로만 사용하면서 UNKNOWN != FREE fail-closed 정책을 보존하기 위해서다.
   영향 범위 - OpenCode Free model discovery와 선택 model health check에만 적용된다.
   */
  func models(apiKey: String) async throws -> [AIModelInfo] {
    async let zen = fetch(source: .zen, apiKey: apiKey)
    async let go = fetch(source: .go, apiKey: apiKey)
    let zenModels = (try? await zen) ?? []
    let goModels = (try? await go) ?? []
    let candidates = zenModels + goModels
    let free = candidates.filter(isFree).map { model in
      let id = "\(model.source.rawValue)/\(model.id)"
      return AIModelInfo(id: id, name: id)
    }
    let deduped = Dictionary(grouping: free, by: \.id).compactMap { $0.value.first }
      .sorted { $0.id < $1.id }
    guard !deduped.isEmpty else {
      throw KakaoLinearError.aiProvider("OpenCode catalog에서 FREE로 확인된 model이 없습니다.")
    }
    return deduped
  }

  private func fetch(
    source: OpenCodeModelID.Source,
    apiKey: String
  ) async throws -> [CatalogModel] {
    let base =
      source == .zen
      ? "https://opencode.ai/zen/v1" : "https://opencode.ai/zen/go/v1"
    guard let url = URL(string: "\(base)/models") else {
      throw KakaoLinearError.aiProvider("OpenCode model URL이 올바르지 않습니다.")
    }
    var request = URLRequest(url: url)
    request.timeoutInterval = 15
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("kakao-linear/0.3.0", forHTTPHeaderField: "User-Agent")
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      throw KakaoLinearError.aiProvider("OpenCode \(source.rawValue) catalog 요청에 실패했습니다.")
    }
    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let entries = root["data"] as? [[String: Any]]
    else {
      throw KakaoLinearError.aiProvider("OpenCode catalog 형식이 올바르지 않습니다.")
    }
    return entries.compactMap { entry in
      guard let id = entry["id"] as? String, !id.isEmpty else { return nil }
      return CatalogModel(source: source, id: id, prices: prices(entry))
    }
  }

  private func prices(_ entry: [String: Any]) -> [Double] {
    let raw = (entry["cost"] ?? entry["pricing"] ?? entry["price"]) as? [String: Any]
    guard let raw else { return [] }
    var values = [raw["input"], raw["output"], raw["cache_read"], raw["cache_write"]]
      .compactMap(number)
    if let cache = raw["cache"] as? [String: Any] {
      values.append(contentsOf: [cache["read"], cache["write"]].compactMap(number))
    }
    return values
  }

  private func number(_ value: Any?) -> Double? {
    if let number = value as? NSNumber { return number.doubleValue }
    if let string = value as? String { return Double(string) }
    return nil
  }

  private func isFree(_ model: CatalogModel) -> Bool {
    if model.prices.contains(where: { $0 > 0 }) { return false }
    let explicitFreeId = model.id.hasSuffix("-free") || model.id.contains("-free-")
    switch model.source {
    case .zen:
      let explicitZero = !model.prices.isEmpty && model.prices.allSatisfy { $0 == 0 }
      return explicitZero || model.id == "big-pickle" || explicitFreeId
    case .go:
      return explicitFreeId
    }
  }
}
