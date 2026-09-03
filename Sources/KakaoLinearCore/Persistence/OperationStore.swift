import Foundation

struct UploadedLinearAsset: Codable, Equatable, Sendable {
  let attachmentId: String
  let name: String
  let mimeType: String
  let assetURL: URL
}

struct LinearOperation: Codable, Equatable, Sendable {
  let id: String
  let draftId: String
  let createdAt: Date
  var uploadedAssets: [UploadedLinearAsset]
  var result: LinearIssueResult?
}

actor OperationStore {
  private let paths: AppSupportPaths

  init(paths: AppSupportPaths = AppSupportPaths()) {
    self.paths = paths
  }

  func existing(draftId: String) throws -> LinearOperation? {
    try paths.ensureDirectories()
    let files = try FileManager.default.contentsOfDirectory(
      at: paths.operations,
      includingPropertiesForKeys: nil
    )
    for file in files where file.pathExtension == "json" {
      if let operation = try? JSONDecoder.kakaoLinear.decode(
        LinearOperation.self,
        from: Data(contentsOf: file)
      ), operation.draftId == draftId {
        return operation
      }
    }
    return nil
  }

  func create(draftId: String) throws -> LinearOperation {
    let operation = LinearOperation(
      id: UUID().uuidString.lowercased(),
      draftId: draftId,
      createdAt: Date(),
      uploadedAssets: [],
      result: nil
    )
    try save(operation)
    return operation
  }

  func save(_ operation: LinearOperation) throws {
    try paths.ensureDirectories()
    let url = paths.operations.appending(path: "\(operation.id).json")
    try JSONEncoder.kakaoLinear.encode(operation).write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }
}
