import Foundation
import Security

public enum SecretKind: String, Sendable {
  case aiAPIKey = "ai-api-key"
  case alibabaTokenPlanAPIKey = "alibaba-token-plan-api-key"
  case openCodeAPIKey = "opencode-api-key"
  case liteLLMAPIKey = "litellm-api-key"
  case linearAPIKey = "linear-api-key"
}

public struct KeychainSecretStore: Sendable {
  private let service = "com.kakaotolinear.secrets"

  public init() {}

  public func set(_ value: String, for kind: SecretKind) throws {
    guard !value.isEmpty else {
      throw KakaoLinearError.invalidInput("빈 secret은 저장할 수 없습니다.")
    }
    let data = Data(value.utf8)
    // 이미 항목이 있으면 ACL(신뢰 앱, "항상 허용")을 보존한 채 값만 갱신한다.
    // (delete+insert를 하면 사용자가 누른 "항상 허용" ACL이 매번 초기화되어 재프롬프트가 생긴다)
    let exists = SecItemCopyMatching(baseQuery(kind) as CFDictionary, nil) == errSecSuccess
    if exists {
      var update = baseQuery(kind)
      update[kSecValueData] = data
      let status = SecItemUpdate(update as CFDictionary, [kSecValueData: data] as CFDictionary)
      guard status == errSecSuccess else { throw keychainError(status) }
      return
    }
    var insert = baseQuery(kind)
    insert[kSecValueData] = data
    insert[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    // 새 항목일 때만 현재 앱이 항상 접근 허용되도록 ACL을 명시한다.
    if let access = Self.currentAppAccessAccess() {
      insert[kSecAttrAccess] = access
    }
    let insertStatus = SecItemAdd(insert as CFDictionary, nil)
    guard insertStatus == errSecSuccess else { throw keychainError(insertStatus) }
  }

  public func get(_ kind: SecretKind) throws -> String? {
    var query = baseQuery(kind)
    query[kSecReturnData] = true
    query[kSecMatchLimit] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = result as? Data else {
      throw keychainError(status)
    }
    return String(data: data, encoding: .utf8)
  }

  public func delete(_ kind: SecretKind) throws {
    let status = SecItemDelete(baseQuery(kind) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw keychainError(status)
    }
  }

  /*
   변경 전 정책 - 항목 접근 ACL을 지정하지 않아 미서명/debug 프로세스가 접근할 때
     macOS가 "키체인 항목 접근 허용" 프롬프트를 반복 요구했다. 또한 set마다 delete+insert를 해
     사용자가 누른 "항상 허용"(ACL)이 매번 초기화돼 재프롬프트가 생겼다.
   변경 후 정책 - 새 항목 생성 시 kSecAttrAccess로 현재 앱을 신뢰 앱으로 추가하고,
     이미 있는 항목은 값을 update만 하여 기존 ACL("항상 허용")을 보존한다.
   변경 이유 - "항상 허용"을 눌러도 서명이 없는 debug 프로세스는 ACL에 기록되지 않아 매번 다시
     요구되던 문제와, set 시 ACL 초기화로 인한 재프롬프트 문제를 함께 해결.
   영향 범위 - 키체인 항목 저장/조회/삭제 전반. 신규 항목은 이 프로세스에 대한 접근 허용 ACL을 갖는다.
   */
  private static func currentAppAccessAccess() -> SecAccess? {
    var trusted: SecTrustedApplication?
    guard SecTrustedApplicationCreateFromPath(nil, &trusted) == errSecSuccess, let trusted else {
      return nil
    }
    let trustedApps = [trusted] as CFArray
    var access: SecAccess?
    let status = SecAccessCreate(
      "com.kakaotolinear.secrets" as CFString, trustedApps, &access)
    return status == errSecSuccess ? access : nil
  }

  private func baseQuery(_ kind: SecretKind) -> [CFString: Any] {
    [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: service,
      kSecAttrAccount: kind.rawValue,
    ]
  }

  private func keychainError(_ status: OSStatus) -> KakaoLinearError {
    let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
    return .permission("Keychain 작업에 실패했습니다: \(message)")
  }
}
