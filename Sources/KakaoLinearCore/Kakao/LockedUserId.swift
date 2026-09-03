import Foundation

final class LockedUserId: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: Int64?

  var value: Int64? {
    lock.withLock { stored }
  }

  func setIfEmpty(_ value: Int64) {
    lock.withLock {
      if stored == nil { stored = value }
    }
  }
}
