# Phase 0 — KakaoTalk macOS Research Spike

## 결론

Phase 0의 핵심 가설은 “현재 KakaoTalk macOS local data에서 room, message, attachment relationship과 full attachment를 CLI로 복구할 수 있다”다.

2026-09-02 기준 SQLCipher/Pkv2 알고리즘, synthetic fixture, KakaoTalk 26.7.0 live database와 attachment를 모두 검증했다. Phase 0은 **live acceptance complete** 상태다.

## 만들지 말아야 할 이유

1. KakaoTalk local schema와 key derivation은 undocumented라 앱 update 한 번에 깨질 수 있다.
2. unofficial automation은 Kakao 운영정책 또는 이용약관 리스크가 있다. server login이나 자체 protocol 구현은 범위에서 제외한다.
3. generic file은 local full cache가 없고 presigned CDN URL도 만료되므로 오래된 첨부를 항상 복구할 수 없다.

가장 약한 고리는 1번이다. 그래서 AI/Linear/GUI보다 native read path를 먼저 acceptance 대상으로 삼는다.

## 확인한 환경

- Apple Silicon
- Swift `6.3.3`
- Xcode `26.6`
- KakaoTalk bundle id `com.kakao.KakaoTalkMac`
- KakaoTalk version `26.7.0 (1194)`
- KakaoTalk process running
- container path exists

```text
~/Library/Containers/com.kakao.KakaoTalkMac/
```

최종 live doctor는 다음 결과를 반환했다.

```text
kakaoRunning    true
accessibility   true
fullDiskAccess  true
kakaoDatabase   true
```

메시지 본문이나 private database filename은 조사 log에 출력하지 않았다.

## Storage contract

### SQLCipher

```text
database directory
~/Library/Containers/com.kakao.KakaoTalkMac/Data/Library/
  Application Support/com.kakao.KakaoTalkMac/

database filename
78 lowercase hex, optional .db
```

open order:

```sql
PRAGMA key = '<256 lowercase hex>';
PRAGMA cipher_compatibility = 3;
```

database는 read-only flag로 열되 `immutable` mode를 사용하지 않는다. 실행 중인 KakaoTalk의 WAL row를 읽어야 하기 때문이다.

### Message schema

주요 table/column:

```text
NTChatRoom
  chatId, type, chatName, directChatMemberUserId

NTChatMessage
  chatId, logId, authorId, type, message, sentAt,
  attachment, supplement

NTUser
  userId, friendNickName, displayName, nickName

NTChatMeta
  chatId, type, content, revision
```

주요 message type:

```text
1   text
2   single image
3   video
18  generic file
27  image album
```

### Full media cache

```text
<container>/<account-sha1>/<sha1(reverse(chatId))>/
```

single image:

```text
sha1(reverse("p" + logId)).img
```

album frame:

```text
sha1(reverse("p" + index + "_" + logId)).img
```

video:

```text
sha1(reverse("v" + logId)).vid
```

Pkv2:

```text
magic       4 bytes: Pkv2
iv          16 bytes
ciphertext  AES-256-CBC-PKCS7
key         SHA256(reverse("#" + logId + "%"))
plaintext   256-byte wrapper + original body
```

generic file type 18은 local cache가 없고 CDN full body만 사용한다.

## Resolver policy

```text
local full Pkv2
  → decrypt
  → SHA-1 equals attachment cs

full CDN
  → max 512 MB
  → HTTP 2xx
  → SHA-1 equals attachment cs

otherwise unavailable
```

thumbnail `.thm`은 preview 전용이라 resolver result에 포함하지 않는다.

## Verification

### 실행 확인

- `swift build`: PASS
- `swift test`: PASS, 21 tests
- key derivation independent reference vector: PASS
- secure key format: PASS
- fixture room query: PASS
- fixture message pagination: PASS
- public Pkv2 full-image decrypt/checksum: PASS
- JSON schema envelope: PASS
- invalid room exit code `12`: PASS
- live doctor permission state: PASS

CommonCrypto PBKDF2 적용 후 key derivation tests는 약 `0.044s`에 완료됐다. 교체 전 pure Swift PBKDF2는 같은 tests가 약 `38s` 걸렸다.

### Live 확인

- account SHA-512 one-time recovery와 auth cache: PASS
- live `rooms list`: PASS
- live `messages list`: PASS
- 30 rooms × recent 100 messages type relationship: PASS
- live local Pkv2 full image: PASS
- live CDN album frame 2개: PASS
- live CDN xlsx original file: PASS
- 선택 text 2 + image 1 SourceBundle: PASS

## Phase 0 acceptance checklist

- [x] `kakao-linear doctor`에서 `fullDiskAccess=true`, `kakaoDatabase=true`
- [x] `rooms list`에서 실제 room id/title/activity 확인
- [x] `messages list`에서 text/image/album/file relationship 확인
- [x] recent image의 local full 또는 CDN resolve 확인
- [x] album frame 2개 이상 checksum 확인
- [x] xlsx 원본 filename/body 확보 확인
- [ ] KakaoTalk 종료/권한 거부/expired CDN 실패 경로 확인

위 checklist 통과 전에는 AI/Linear/GUI phase로 넘어가지 않는다.

## Reference implementations

- [NomaDamas/katok](https://github.com/NomaDamas/katok) — SQLCipher reader, media cache, checksum contract
- [JungHoonGhae/openkakao-cli](https://github.com/JungHoonGhae/openkakao-cli) — AX fallback과 최신 KakaoTalk 제약
- [channprj/kmsg](https://github.com/channprj/kmsg) — Swift 6 macOS Accessibility CLI structure
- [SQLCipher.swift](https://github.com/sqlcipher/SQLCipher.swift) — official Swift Package

외부 source code를 복사하지 않고 storage contract와 synthetic reference vector를 독립 Swift implementation으로 옮겼다.
