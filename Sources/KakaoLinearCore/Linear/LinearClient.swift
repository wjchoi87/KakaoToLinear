import Foundation
import UniformTypeIdentifiers

public struct LinearClient: Sendable {
  struct UploadTicket: Sendable {
    struct Header: Sendable {
      let key: String
      let value: String
    }
    let uploadURL: URL
    let assetURL: URL
    let headers: [Header]
  }

  private let graphQL: GraphQLClient
  private let session: URLSession

  public init(
    endpoint: URL,
    apiKey: String,
    session: URLSession = .shared
  ) {
    graphQL = GraphQLClient(endpoint: endpoint, apiKey: apiKey, session: session)
    self.session = session
  }

  public func healthCheck() async -> Bool {
    struct Payload: Decodable { struct Viewer: Decodable { let id: String }; let viewer: Viewer }
    do {
      let _: Payload = try await graphQL.execute(query: "query Viewer { viewer { id } }")
      return true
    } catch {
      return false
    }
  }

  public func teams() async throws -> [LinearTeam] {
    struct Payload: Decodable {
      struct Connection: Decodable { let nodes: [LinearTeam] }
      let teams: Connection
    }
    let payload: Payload = try await graphQL.execute(
      query: "query Teams { teams(first: 250) { nodes { id key name } } }"
    )
    return payload.teams.nodes.sorted { $0.name < $1.name }
  }

  public func projects(teamId: String) async throws -> [LinearProject] {
    struct Payload: Decodable {
      struct Team: Decodable {
        struct Connection: Decodable { let nodes: [LinearProject] }
        let projects: Connection
      }
      let team: Team
    }
    let payload: Payload = try await graphQL.execute(
      query: """
        query TeamProjects($teamId: String!) {
          team(id: $teamId) { projects(first: 250) { nodes { id name } } }
        }
        """,
      variables: ["teamId": .string(teamId)]
    )
    return payload.team.projects.nodes.sorted { $0.name < $1.name }
  }

  public func statuses(teamId: String) async throws -> [LinearStatus] {
    struct Payload: Decodable {
      struct Team: Decodable {
        struct Connection: Decodable { let nodes: [LinearStatus] }
        let states: Connection
      }
      let team: Team
    }
    let payload: Payload = try await graphQL.execute(
      query: """
        query TeamStates($teamId: String!) {
          team(id: $teamId) { states { nodes { id name type } } }
        }
        """,
      variables: ["teamId": .string(teamId)]
    )
    return payload.team.states.nodes
  }

  public func members(teamId: String) async throws -> [LinearMember] {
    struct Payload: Decodable {
      struct Team: Decodable {
        struct Connection: Decodable { let nodes: [LinearMember] }
        let members: Connection
      }
      let team: Team
    }
    let payload: Payload = try await graphQL.execute(
      query: """
        query TeamMembers($teamId: String!) {
          team(id: $teamId) { members(first: 250) { nodes { id name email } } }
        }
        """,
      variables: ["teamId": .string(teamId)]
    )
    return payload.team.members.nodes.sorted { $0.name < $1.name }
  }

  public func labels(teamId: String) async throws -> [LinearLabel] {
    struct Payload: Decodable {
      struct Team: Decodable {
        struct Connection: Decodable { let nodes: [LinearLabel] }
        let labels: Connection
      }
      let team: Team
    }
    let payload: Payload = try await graphQL.execute(
      query: """
        query TeamLabels($teamId: String!) {
          team(id: $teamId) { labels(first: 250) { nodes { id name color } } }
        }
        """,
      variables: ["teamId": .string(teamId)]
    )
    return payload.team.labels.nodes.sorted { $0.name < $1.name }
  }

  func issue(id: String) async throws -> LinearIssueResult? {
    struct Payload: Decodable {
      struct Issue: Decodable {
        let id: String
        let identifier: String
        let url: URL
        let title: String
      }
      let issue: Issue?
    }
    do {
      let payload: Payload = try await graphQL.execute(
        query: "query Issue($id: String!) { issue(id: $id) { id identifier url title } }",
        variables: ["id": .string(id)]
      )
      return payload.issue.map {
        LinearIssueResult(id: $0.id, identifier: $0.identifier, url: $0.url, title: $0.title)
      }
    } catch {
      return nil
    }
  }

  func createIssue(
    id: String,
    draft: IssueDraft,
    description: String,
    options: LinearIssueOptions
  ) async throws -> LinearIssueResult {
    struct Payload: Decodable {
      struct IssueCreate: Decodable {
        struct Issue: Decodable {
          let id: String
          let identifier: String
          let url: URL
          let title: String
        }
        let success: Bool
        let issue: Issue?
      }
      let issueCreate: IssueCreate
    }
    var input: [String: JSONValue] = [
      "id": .string(id),
      "title": .string(draft.title),
      "description": .string(description),
      "teamId": .string(options.teamId),
      "priority": .int(options.priority.apiValue),
    ]
    if let projectId = options.projectId { input["projectId"] = .string(projectId) }
    if let statusId = options.statusId { input["stateId"] = .string(statusId) }
    if let assigneeId = options.assigneeId { input["assigneeId"] = .string(assigneeId) }
    if !options.labelIds.isEmpty {
      input["labelIds"] = .array(options.labelIds.map(JSONValue.string))
    }
    let payload: Payload = try await graphQL.execute(
      query: """
        mutation IssueCreate($input: IssueCreateInput!) {
          issueCreate(input: $input) { success issue { id identifier url title } }
        }
        """,
      variables: ["input": .object(input)]
    )
    guard payload.issueCreate.success, let issue = payload.issueCreate.issue else {
      throw KakaoLinearError.linearAPI("Linear issueCreate가 성공 결과를 반환하지 않았습니다.")
    }
    return LinearIssueResult(
      id: issue.id,
      identifier: issue.identifier,
      url: issue.url,
      title: issue.title
    )
  }

  func upload(_ resolved: ResolvedAttachment) async throws -> UploadedLinearAsset {
    let name = resolved.attachment.originalName ?? resolved.fileURL.lastPathComponent
    let type = mimeType(for: resolved.fileURL, declared: resolved.attachment.mimeType)
    let attributes = try FileManager.default.attributesOfItem(atPath: resolved.fileURL.path)
    guard let size = (attributes[.size] as? NSNumber)?.intValue else {
      throw KakaoLinearError.linearAPI("attachment 크기를 읽지 못했습니다: \(name)")
    }
    let ticket = try await uploadTicket(filename: name, contentType: type, size: size)
    var request = URLRequest(url: ticket.uploadURL)
    request.httpMethod = "PUT"
    request.timeoutInterval = 120
    request.setValue(type, forHTTPHeaderField: "Content-Type")
    request.setValue("public, max-age=31536000", forHTTPHeaderField: "Cache-Control")
    for header in ticket.headers { request.setValue(header.value, forHTTPHeaderField: header.key) }
    let data = try Data(contentsOf: resolved.fileURL, options: [.mappedIfSafe])
    let (_, response) = try await session.upload(for: request, from: data)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      throw KakaoLinearError.linearAPI("Linear storage upload에 실패했습니다: \(name)")
    }
    return UploadedLinearAsset(
      attachmentId: resolved.attachment.id,
      name: name,
      mimeType: type,
      assetURL: ticket.assetURL
    )
  }

  private func uploadTicket(filename: String, contentType: String, size: Int) async throws
    -> UploadTicket
  {
    struct Payload: Decodable {
      struct FileUpload: Decodable {
        struct UploadFile: Decodable {
          struct Header: Decodable { let key: String; let value: String }
          let uploadUrl: URL
          let assetUrl: URL
          let headers: [Header]
        }
        let success: Bool
        let uploadFile: UploadFile?
      }
      let fileUpload: FileUpload
    }
    let payload: Payload = try await graphQL.execute(
      query: """
        mutation FileUpload($filename: String!, $contentType: String!, $size: Int!) {
          fileUpload(filename: $filename, contentType: $contentType, size: $size) {
            success uploadFile { uploadUrl assetUrl headers { key value } }
          }
        }
        """,
      variables: [
        "filename": .string(filename),
        "contentType": .string(contentType),
        "size": .int(size),
      ]
    )
    guard payload.fileUpload.success, let upload = payload.fileUpload.uploadFile else {
      throw KakaoLinearError.linearAPI("Linear fileUpload URL 발급에 실패했습니다.")
    }
    return UploadTicket(
      uploadURL: upload.uploadUrl,
      assetURL: upload.assetUrl,
      headers: upload.headers.map { UploadTicket.Header(key: $0.key, value: $0.value) }
    )
  }

  private func mimeType(for url: URL, declared: String?) -> String {
    if let declared, !declared.isEmpty { return declared }
    return UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
      ?? "application/octet-stream"
  }
}
