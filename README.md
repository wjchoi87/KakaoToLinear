# KakaoToLinear — KakaoTalk → Linear Issue Maker for macOS

KakaoTalk 업무 요청을 사용자가 직접 선택하고, AI가 구조화한 뒤 Linear issue로 등록하는 local-first macOS 도구다.

```text
⌥⌘L
→ 채팅방 선택
→ 메시지/첨부 선택
→ AI 정리·재정리
→ Linear metadata 선택
→ 이슈 생성
```

모든 business logic은 `KakaoLinearCore`에 있고 CLI와 SwiftUI app이 같은 Core API를 호출한다.

## 구현 범위

### Kakao Core

- KakaoTalk 26.x SQLCipher DB discovery/key derivation
- direct preference id와 active account SHA-512 one-time recovery
- room/current room/message pagination
- text, image, album, video, generic file relationship
- 선택된 attachment만 resolve
- local Pkv2 full cache AES decrypt + SHA-1 검증
- checksum이 있는 full CDN fallback
- thumbnail을 Linear attachment로 사용하지 않음
- filename path traversal, bidi override, duplicate 방어

### AI

- `codex-subscription`: Codex CLI의 기존 ChatGPT/Codex plan 로그인 사용, API key 불필요
- `alibaba-token-plan`: xal-plugins의 endpoint/model 규약을 참고한 native provider
- `opencode-free`: xal-plugins와 같은 fail-closed FREE catalog 판정을 직접 구현
- `litellm`: configured proxy를 직접 호출하며 key는 optional
- `openai-compatible`: 기존 `/chat/completions` API fallback
- Codex token·OAuth 파일을 직접 읽거나 복사하지 않음
- image는 원본을 바꾸지 않고 long edge 2048px JPEG context로 최적화
- TXT/MD/CSV/JSON text context
- PDF/Office/HWP/video는 Linear attachment only
- 2-pass AI 파이프라인: PASS 1 evidence 분석 → PASS 2 issue 합성
  - `analyze`로 evidence만 추출하고 `compose`에서 원문+evidence로 최종 이슈 작성
  - evidence(사실/요청/제약/조건/제외/모호점/관계/첨부인사이트)는 JSON으로 보존
  - source hash 기반 evidence cache로 동일 source 재분석 방지
- structured `IssueDraft` + `EvidenceAnalysis`
- immutable `SourceBundle` + versioned compose/revise/manual-edit draft

### Linear

- Team, Project, Status, Member, Label API metadata
- TTL cache와 `--refresh`
- signed `fileUpload` → PUT → private asset URL
- provenance Markdown description
- room별 metadata default 저장
- deterministic operation UUID와 local operation record
- process/network 재시도 시 duplicate issue 방지
- `--force`일 때만 동일 draft 중복 허용
- `--dry-run`

### macOS App

- MenuBarExtra
- global hotkey 기본 `⌥⌘L`
- 설정에서 `⌥⌘L`, `⌥⌘I`, `⇧⌘L` 선택
- room picker
- room favorite persistence와 favorite/other disclosure group
- message plain single, Command additive toggle, Shift range, Command-Shift additive range, ⌘A
- AI review/revision/manual edit
- Linear metadata form
- result/open/copy
- permission/empty/loading/error state
- Keychain secret storage

### CLI

```bash
kakao-linear doctor
kakao-linear rooms list
kakao-linear rooms current
kakao-linear rooms favorite --room room_123
kakao-linear rooms favorites --json
kakao-linear rooms unfavorite --room room_123
kakao-linear messages list --room room_123 --limit 100
kakao-linear attachment get --id att_456_0 --output ./resolved

kakao-linear source create \
  --room room_123 \
  --message msg_101 \
  --message msg_102

kakao-linear compose --source src_x
kakao-linear revise --draft draft_x --instruction "PC 범위는 제외해"
echo "태블릿 완료 조건 추가" | kakao-linear revise --draft draft_x --stdin

# 2-pass: evidence 분석만 수행 (--json으로 확인)
kakao-linear analyze --source src_x
kakao-linear analyze --source src_x --json
# compose는 기본적으로 analyze를 내부에서 수행하고 evidence를 cache한다.
# 캐시 대신 강제 재분석하려면:
kakao-linear analyze --source src_x --force-analyze --json
# 미리 분석한 evidence id를 특정해 compose/revise에 전달할 수도 있다.
kakao-linear compose --source src_x --evidence evidence_xxx

kakao-linear linear teams --json
kakao-linear linear projects --team ENG --json
kakao-linear linear statuses --team ENG --json
kakao-linear linear members --team ENG --json
kakao-linear linear labels --team ENG --json

kakao-linear linear create \
  --draft draft_x \
  --team ENG \
  --project project_uuid \
  --status state_uuid \
  --assignee user_uuid \
  --priority high \
  --label label_uuid \
  --dry-run
```

모든 JSON output은 다음 envelope를 사용한다.

```json
{
  "schemaVersion": 1,
  "data": {}
}
```

`--json` stdout에는 JSON 외 문자열을 출력하지 않는다. 오류 설명은 stderr로 보낸다.

## Build

요구사항:

- Apple Silicon Mac
- macOS 14+
- Swift 6.2+
- KakaoTalk for macOS

CLI:

```bash
swift build -c release --product kakao-linear
.build/release/kakao-linear --version
```

App bundle:

```bash
./scripts/build-app.sh
open dist/KakaoToLinear.app
```

build script는 SQLCipher framework를 embed하고 app rpath를 추가한 뒤 ad-hoc sign한다. 배포용 build는 Apple Developer ID signing/notarization으로 교체해야 한다.

## 실행 방법 (정확한 경로)

빌드는 프로젝트 루트(`/Users/wjchoi/kakao-issue-maker`)에서 실행한다.

### CLI

```bash
# 프로젝트 루트에서
swift build            # debug 빌드 (.build/debug/kakao-linear)
swift build -c release # release 빌드 (.build/release/kakao-linear)

# 실행 (DEBUG). 홈 격리 테스트:
KAKAO_LINEAR_HOME=/tmp/kl-test .build/debug/kakao-linear --version
./.build/debug/kakao-linear doctor --human

# release 실행:
./.build/release/kakao-linear --version
```

### macOS 앱 (SwiftUI)

```bash
# 1) 앱 번들 빌드 (SQLCipher embed + ad-hoc sign)
./scripts/build-app.sh

# 2) 실행 — 번들 경로는 항상 dist/KakaoToLinear.app
open dist/KakaoToLinear.app
# 또는
dist/KakaoToLinear.app/Contents/MacOS/KakaoToLinearApp
```

- 빌드된 실행 파일 경로: `dist/KakaoToLinear.app/Contents/MacOS/KakaoToLinearApp`
- 첫 실행 후 macOS 권한(Full Disk Access / Accessibility)이 필요할 수 있다:
  System Settings → Privacy & Security → 해당 항목에서 `KakaoToLinearApp` 또는 실행하는 터미널에 허용.
- 메뉴바 아이콘(⌥⌘L) → "새 Linear 이슈…"로 창을 연다.

> 개발 중 만든 창이 안 보이면: Dock이나 메뉴바에서 활성화, 또는 ⌥⌘L 단축키를 다시 눌러 창을 앞으로.

## 배포

### 0. Sparkle 자동 업데이트 (GitHub Releases 기반)

앱은 [Sparkle](https://sparkle-project.org)로 업데이트를 확인한다. `Info.plist`의 `SUFeedURL`이 가리키는 appcast를 GitHub Pages/raw URL로 서빙하고, 앱/Sparkle 프레임워크는 같은 Developer ID로 서명돼야 한다.

**첫 설정 (한 번만)**

```bash
# 1) EdDSA 업데이트 서명 키 생성 (Sparkle 공식 툴)
#    Sparkle의 generate_keys 툴을 사용한다.
cd /path/to/Sparkle/bin
./generate_keys
# Private Key는 절대 커밋하지 말 것. Public Key를 Info.plist SUPublicEDKey에 넣는다.

# 2) Info.plist에 넣은 후 앱 재빌드:
#    SUFeedURL  = https://raw.githubusercontent.com/wjchoi87/KakaoToLinear/main/appcast.xml
#    SUPublicEDKey = <위에서 생성한 공개키>
```

**새 버전 릴리즈 절차**

```bash
# 1) 버전 올리기: Package.swift/Info.plist의 CPBundleShortVersionString/CFBundleVersion을 올린다.
# 2) 서명+notarize 된 앱 빌드 (아래 "### 1" 절차)
./scripts/build-app.sh          # ad-hoc용 번들 생성은 이 스크립트로
# Developer ID 서명 + notarize + staple (아래 1번 절차)

# 3) zip 만들고 서명 + appcast 갱신 (Sparkle 공식 툴)
./bin/sign_update dist/KakaoToLinear-0.2.0.zip
#      ↑ 이 출력(ed25519 서명)을 appcast.xml의 <sparkle:edSignature>에 넣는다.

# 4) appcast.xml 갱신 예시 (실제 버전으로 작성)
cat > appcast.xml <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>KakaoToLinear Updates</title>
    <item>
      <title>KakaoToLinear 0.2.0</title>
      <sparkle:version>1</sparkle:version>
      <sparkle:shortVersionString>0.2.0</sparkle:shortVersionString>
      <enclosure url="https://github.com/wjchoi87/KakaoToLinear/releases/download/v0.2.0/KakaoToLinear-0.2.0.zip"
                 sparkle:edSignature="<sign_update 출력>"
                 length="<zip 바이트 크기>"
                 type="application/octet-stream"/>
      <sparkle:releaseNotesLink>https://github.com/wjchoi87/KakaoToLinear/releases/tag/v0.2.0</sparkle:releaseNotesLink>
    </item>
  </channel>
</rss>
XML

# 5) GitHub에 커밋(appcast.xml) 후 릴리즈 생성
gh release create v0.2.0 dist/KakaoToLinear-0.2.0.zip --title "KakaoToLinear 0.2.0" --notes "..."
```

- `appcast.xml`은 `SUFeedURL`과 같은 원격 주소로 서빙해야 앱이 읽는다 (raw.githubusercontent.com 또는 GitHub Pages).
- 업데이트가 실제로 동작하려면 **앱과 Sparkle.framework, 배포 zip 모두 같은 Developer ID로 서명**돼야 한다. ad-hoc 서명 상태에서는 Sparkle이 업데이트를 거부한다.

### 1. Apple Developer ID 서명 + notarize (배포용)

현재 `scripts/build-app.sh`는 ad-hoc(`codesign --sign -`) 서명이라 Gatekeeper 통과용 배포에는 부족하다. 배포하려면:

1. **Developer ID 어플리케이션 인증서** 확보 (Apple Developer 계정).
2. build script의 서명을 교체하거나 build 후 재서명:

```bash
# Developer ID로 서명
codesign --force --deep --sign "Developer ID Application: Your Name (TEAMID)" \
  --options runtime dist/KakaoToLinear.app

# after build script가 만든 ad-hoc 서명을 제거하고 다시 서명
codesign --force --deep --sign - dist/KakaoToLinear.app
```

3. **notarize** (Apple notary service):
```bash
ditto -c -k --keepParent dist/KakaoToLinear.app dist/KakaoToLinear.zip
xcrun notarytool submit dist/KakaoToLinear.zip \
  --apple-id "you@example.com" \
  --team-id "TEAMID" \
  --password "app-specific-password" --wait

# 스테이플(stapler)로 노치 부착
xcrun staple dist/KakaoToLinear.app
```

4. 서명 검증:
```bash
codesign --verify --deep --strict dist/KakaoToLinear.app
spctl -a -vv dist/KakaoToLinear.app
```

### 2. Homebrew cask 등록

이 앱은 설치형 cask가 아니라 **다운로드형 zipped 앱 cask**에 적합하다. 절차:

1. **릴리스 asset 준비**: GitHub Releases에 `KakaoToLinear-<버전>.zip`(notarized 된 .app을 묶은 것)을 업로드. URL은 안정적이어야 하며 버전별로 고정.

2. **cask 파일 작성**: [homebrew-cask](https://github.com/Homebrew/homebrew-cask)에 PR을 열어 `Casks/k/kakao-linear.rb` 추가.

```ruby
cask "kakao-linear" do
  version "0.2.0"
  sha256 "NEWMD5OFTHEZIP"   # 실제 zip의 sha256

  url "https://github.com/wjchoi87/KakaoToLinear/releases/download/v#{version}/KakaoToLinear-#{version}.zip"
  name "KakaoToLinear"
  desc "Local-first KakaoTalk to Linear issue maker"
  homepage "https://github.com/wjchoi87/KakaoToLinear"

  app "KakaoToLinear.app"

  zap trash: "~/Library/Application Support/KakaoToLinear"
end
```

- `sha256`은 `shasum -a 256 KakaoToLinear-0.2.0.zip`로 계산해 채운다.
- homebrew-cask CI(`brew cask audit kakao-linear`, `brew style`)를 통과해야 병합된다.
- 일반적으로 **홈브루에 등록하려면 기여(PR)가 필요**하며, homebrew-core(cask)는 오픈소스 리포에 대한 공개 PR로만 추가된다. 사설 소프트웨어는 `brew tap wjchoi87/tap` 형태의 **개인 tap**을 만드는 게 일반적.

3. **(선택) 개인 tap** (사내/사설 배포):
```bash
# tap 저장소에 Casks/kakao-linear.rb 올리고
brew tap wjchoi87/tap
brew install --cask <tap>/kakao-linear
```

### 3. DMG (선택)

`.dmg`로 배포하면 Finder 드래그 설치가 가능하다:
```bash
hdiutil create -volname KakaoToLinear -srcfolder dist/KakaoToLinear.app -ov \
  -format UDZO dist/KakaoToLinear.dmg
```

## 최초 설정

### 1. macOS 권한

System Settings → Privacy & Security에서 `KakaoToLinear.app` 또는 CLI를 실행하는 Terminal에 허용한다.

- Full Disk Access: KakaoTalk SQLCipher DB/media
- Accessibility: 현재 열린 room과 UI fallback context

```bash
kakao-linear doctor --human
```

Kakao account id가 preference에 직접 없으면 active account SHA-512에서 최초 1회 병렬 복구하고 아래에 mode `0600` cache를 만든다.

```text
~/Library/Application Support/KakaoToLinear/kakao/auth.json
```

SQLCipher key 자체는 저장하지 않는다.

### 2. AI

기본 provider는 ChatGPT/Codex plan을 쓰는 `codex-subscription`이다.

```bash
kakao-linear ai providers --json
kakao-linear ai use --provider codex-subscription
codex login
```

지원 provider:

| Provider | 선택 명령 | Credential owner | Image context |
| --- | --- | --- | --- |
| GPT ChatGPT/Codex Plan | `ai use --provider codex-subscription` | Codex CLI | 지원 |
| Alibaba Token Plan | `ai use --provider alibaba-token-plan --model qwen3.6-flash` | KakaoToLinear Keychain | 지원 |
| OpenCode Free | `ai use --provider opencode-free --model zen/big-pickle` | KakaoToLinear Keychain | text-only |
| LiteLLM | `ai use --provider litellm --model <id>` | KakaoToLinear Keychain, optional | 설정에 따름 |
| Generic API | `ai use --provider openai-compatible --model <id>` | KakaoToLinear Keychain | 지원 |

Token-plan/free/proxy provider setup:

```bash
kakao-linear ai use --provider alibaba-token-plan --model qwen3.6-flash
kakao-linear auth ai

kakao-linear ai use --provider opencode-free --model zen/big-pickle
kakao-linear auth ai
kakao-linear ai models --provider opencode-free --json

kakao-linear ai use --provider litellm --model <model-id>
kakao-linear config set ai.base-url http://localhost:4000/v1
kakao-linear auth ai   # no-key proxy면 '-' 입력
```

OpenAI-compatible API fallback만 다음 설정과 Keychain을 사용한다.

```bash
kakao-linear config set ai.base-url http://localhost:4000/v1
kakao-linear ai use --provider openai-compatible --model qwen
kakao-linear auth ai
```

Claude subscription credential을 우회 사용하거나 Claude token file을 읽는 provider는 포함하지 않는다.

### 3. Linear

```bash
kakao-linear auth linear
kakao-linear linear teams --json
```

Linear personal API key는 Keychain에만 저장한다.

## Local persistence

```text
~/Library/Application Support/KakaoToLinear/
├─ config.json
├─ room-mappings.json
├─ room-favorites.json
├─ kakao/auth.json
├─ cache/
│  ├─ resolved/
│  └─ linear-metadata/
├─ sources/
├─ drafts/
├─ evidence/
├─ logs/
│  └─ ai-errors.log
└─ operations/
```

`KAKAO_LINEAR_HOME=/temporary/path`로 CLI/test persistence root를 격리할 수 있다.

## Privacy

- 선택하지 않은 Kakao message는 AI request에 포함하지 않는다.
- 기본 log에 room title, sender, message body, filename을 남기지 않는다.
- source/draft/local attachment는 local disk에만 저장한다.
- AI provider에는 선택된 source와 허용된 attachment context만 전송한다.
- attachment CDN body는 checksum 검증 전 저장하지 않는다.
- API key는 config/file/log가 아닌 macOS Keychain에 저장한다.
- Codex credential은 Codex CLI가 소유하며 KakaoToLinear는 process invocation만 수행한다.
- Alibaba/OpenCode/LiteLLM credential은 provider별로 분리된 macOS Keychain item에 저장한다.
- Codex provider는 `--ephemeral`, empty temporary workspace, read-only sandbox, output schema로 실행한다.

## Exit codes

```text
0   success
10  permission
11  kakao-not-running
12  room-not-found
13  message-not-found
20  attachment-resolution
30  ai-provider
40  linear-api
50  invalid-input
60  already-created
```

## Test / Verification

```bash
swift format lint --recursive --strict --configuration .swift-format Sources Tests Package.swift
swift test
./scripts/build-app.sh
codesign --verify --deep --strict dist/KakaoToLinear.app
```

AI provider regression에는 실제 synthetic fixture 기반 Codex plan compose, mock HTTP 기반 Alibaba/LiteLLM-compatible transport, OpenCode Free catalog/endpoint test가 포함된다. Alibaba/OpenCode live 호출은 KakaoToLinear Keychain에 provider key를 입력한 뒤 실행한다.

fixture CLI:

```bash
KAKAO_LINEAR_HOME=$(mktemp -d) \
  .build/debug/kakao-linear source create \
  --fixture Tests/KakaoLinearCoreTests/Fixtures/sample.json \
  --room room_123 \
  --message msg_101 \
  --message msg_103 \
  --json
```

자세한 storage 검증은 [Phase 0 research](docs/phase-0-research-spike.md), UI contract는 [DESIGN.md](DESIGN.md)를 참고한다.

## MVP 외 범위

- 실시간 전체 message 감시
- 무승인 자동 issue 생성
- Windows/mobile
- Kakao server protocol login
- MCP/watch daemon

MCP는 CLI schema가 실제 운영에서 안정화된 뒤 Core adapter만 추가한다.
