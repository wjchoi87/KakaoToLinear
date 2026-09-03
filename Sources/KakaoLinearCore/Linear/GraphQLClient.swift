import Foundation

enum JSONValue: Codable, Sendable {
  case string(String)
  case int(Int)
  case bool(Bool)
  case array([JSONValue])
  case object([String: JSONValue])
  case null

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Int.self) {
      self = .int(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([JSONValue].self) {
      self = .array(value)
    } else {
      self = .object(try container.decode([String: JSONValue].self))
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case let .string(value): try container.encode(value)
    case let .int(value): try container.encode(value)
    case let .bool(value): try container.encode(value)
    case let .array(value): try container.encode(value)
    case let .object(value): try container.encode(value)
    case .null: try container.encodeNil()
    }
  }
}

struct GraphQLClient: Sendable {
  private struct Request: Encodable {
    let query: String
    let variables: [String: JSONValue]
  }

  private struct Response<Payload: Decodable>: Decodable {
    struct GraphQLError: Decodable { let message: String }
    let data: Payload?
    let errors: [GraphQLError]?
  }

  let endpoint: URL
  let apiKey: String
  let session: URLSession

  func execute<Payload: Decodable>(
    query: String,
    variables: [String: JSONValue] = [:]
  ) async throws -> Payload {
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.timeoutInterval = 60
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(apiKey, forHTTPHeaderField: "Authorization")
    request.httpBody = try JSONEncoder().encode(Request(query: query, variables: variables))
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      throw KakaoLinearError.linearAPI("Linear API HTTP 요청에 실패했습니다.")
    }
    let decoded: Response<Payload>
    do {
      decoded = try JSONDecoder().decode(Response<Payload>.self, from: data)
    } catch {
      throw KakaoLinearError.linearAPI("Linear GraphQL 응답 형식을 읽지 못했습니다.")
    }
    if let errors = decoded.errors, !errors.isEmpty {
      let message = errors.map(\.message).joined(separator: "; ")
      throw KakaoLinearError.linearAPI("Linear GraphQL 오류: \(message)")
    }
    guard let payload = decoded.data else {
      throw KakaoLinearError.linearAPI("Linear GraphQL 응답 data가 비어 있습니다.")
    }
    return payload
  }
}
