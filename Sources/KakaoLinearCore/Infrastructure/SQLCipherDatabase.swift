import Foundation
import SQLCipher

final class SQLCipherDatabase {
  enum Binding {
    case int64(Int64)
    case text(String)
    case null
  }

  final class Statement {
    fileprivate let pointer: OpaquePointer

    fileprivate init(pointer: OpaquePointer) {
      self.pointer = pointer
    }

    deinit {
      sqlite3_finalize(pointer)
    }

    func step() throws -> Bool {
      let result = sqlite3_step(pointer)
      if result == SQLITE_ROW { return true }
      if result == SQLITE_DONE { return false }
      throw KakaoLinearError.kakaoDatabase("SQLCipher query 실행에 실패했습니다 (code \(result)).")
    }

    func int64(_ index: Int32) -> Int64 {
      sqlite3_column_int64(pointer, index)
    }

    func double(_ index: Int32) -> Double {
      sqlite3_column_double(pointer, index)
    }

    func string(_ index: Int32) -> String? {
      guard sqlite3_column_type(pointer, index) != SQLITE_NULL,
        let text = sqlite3_column_text(pointer, index)
      else { return nil }
      return String(cString: text)
    }
  }

  private var pointer: OpaquePointer?
  private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

  init(url: URL, key: String) throws {
    var database: OpaquePointer?
    let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
    guard sqlite3_open_v2(url.path, &database, flags, nil) == SQLITE_OK,
      let database
    else {
      if let database { sqlite3_close(database) }
      throw KakaoLinearError.kakaoDatabase("KakaoTalk database를 열지 못했습니다.")
    }
    pointer = database

    do {
      try execute("PRAGMA key = '\(key)'; PRAGMA cipher_compatibility = 3;")
      let statement = try prepare("SELECT count(*) FROM sqlite_master")
      guard try statement.step(), statement.int64(0) > 0 else {
        throw KakaoLinearError.kakaoDatabase("KakaoTalk database schema를 읽지 못했습니다.")
      }
    } catch {
      sqlite3_close(database)
      pointer = nil
      throw KakaoLinearError.kakaoDatabase("KakaoTalk SQLCipher key 검증에 실패했습니다.")
    }
  }

  deinit {
    if let pointer { sqlite3_close(pointer) }
  }

  func execute(_ sql: String) throws {
    guard let pointer else { throw KakaoLinearError.kakaoDatabase("Database가 닫혀 있습니다.") }
    var errorPointer: UnsafeMutablePointer<CChar>?
    let result = sqlite3_exec(pointer, sql, nil, nil, &errorPointer)
    if let errorPointer { sqlite3_free(errorPointer) }
    guard result == SQLITE_OK else {
      throw KakaoLinearError.kakaoDatabase("SQLCipher 초기화에 실패했습니다 (code \(result)).")
    }
  }

  func prepare(_ sql: String, bindings: [Binding] = []) throws -> Statement {
    guard let pointer else { throw KakaoLinearError.kakaoDatabase("Database가 닫혀 있습니다.") }
    var statementPointer: OpaquePointer?
    guard sqlite3_prepare_v2(pointer, sql, -1, &statementPointer, nil) == SQLITE_OK,
      let statementPointer
    else {
      throw KakaoLinearError.kakaoDatabase("SQLCipher query 준비에 실패했습니다.")
    }

    for (offset, binding) in bindings.enumerated() {
      let index = Int32(offset + 1)
      let result: Int32
      switch binding {
      case .int64(let value):
        result = sqlite3_bind_int64(statementPointer, index, value)
      case .text(let value):
        result = value.withCString {
          sqlite3_bind_text(statementPointer, index, $0, -1, Self.transient)
        }
      case .null:
        result = sqlite3_bind_null(statementPointer, index)
      }
      guard result == SQLITE_OK else {
        sqlite3_finalize(statementPointer)
        throw KakaoLinearError.kakaoDatabase("SQLCipher parameter binding에 실패했습니다.")
      }
    }
    return Statement(pointer: statementPointer)
  }
}
