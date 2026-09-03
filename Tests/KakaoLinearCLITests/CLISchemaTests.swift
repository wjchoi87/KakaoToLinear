import Foundation
import KakaoLinearCore
import Testing

@Test("CLI JSON envelope schema version은 1이다")
func schemaVersion() throws {
  let envelope = APIEnvelope(data: ["ok": true])
  let data = try JSONEncoder().encode(envelope)
  let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  #expect(object["schemaVersion"] as? Int == 1)
}
