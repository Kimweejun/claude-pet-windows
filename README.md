# clawdex for Windows

Codex 펫(Codex pet)을 **Windows의 Claude Code / Claude 데스크톱 앱**에서 쓰게 해 주는 데스크톱 오버레이입니다.
화면 위에 펫이 떠 있고, Claude가 하는 일(생각 / 도구 실행 / 권한 대기 / 완료)에 맞춰 애니메이션이 바뀝니다.

> 이 프로젝트는 [danielkempe/clawdex](https://github.com/danielkempe/clawdex)(macOS 전용, MIT)의 아이디어와 펫 포맷·훅 방식을 Windows용으로 **새로 구현**한 것입니다. 원본 코드는 사용하지 않았습니다.

A floating desktop pet for Claude Code on Windows. It reuses the Codex pet format (`pet.json` + `spritesheet.webp`, 8×9 atlas) and animates from Claude Code hook events. Windows port/re-implementation of the idea behind [danielkempe/clawdex](https://github.com/danielkempe/clawdex) (macOS only); no code from it is used.

## 기능

- **Claude Code 훅 연동** — 프롬프트 처리·파일 조회 → `review`, Bash/Edit 등 작업 → `running`, 권한 요청 → `waiting`, 응답 완료 → `waving`, 그 외 `idle`
- **새 세션 시작 시 자동 실행** — `SessionStart` 훅이 펫을 켭니다 (컴팩트 때는 켜지 않고, 직접 닫은 펫은 세션 중 되살아나지 않음)
- **Codex 펫 스타일 인터랙션**
  - 마우스를 올리면 손을 흔들고, 발밑의 작은 캡슐이 *새 대화 / 보이스* 버튼으로 펼쳐집니다
  - 드래그하면 방향에 따라 달리는 모션(`running-right` / `running-left`)
  - 클릭하면 Claude 창이 앞으로 나옵니다
- **선명한 렌더링** — 모니터 DPI에 맞춰 Lanczos로 다시 그립니다 (WebP 알파 보존)
- **크기 조절** — 트레이 아이콘 좌클릭(슬라이더), 마우스 휠, 우클릭 메뉴
- **펫 교체** — `~/.codex/pets/` 와 `~/.clawdex/pets/` 의 펫을 자동 인식 (Codex 펫은 수정 없이 사용)
- **끄기 / 다시 켜기** — 호버 시 나타나는 ✕ 버튼 / 바탕화면의 `Clawdex Pet` 바로가기

## 요구 사항

- Windows 10/11, Windows PowerShell 5.1 (기본 내장), .NET Framework 4.x (기본 내장)
- Claude Code (훅은 `~/.claude/settings.json` 사용자 설정에 등록됩니다)
- Node, git, Python 등 **별도 설치 불필요**

## 설치

```powershell
git clone https://github.com/Kimweejun/claude-pet-windows
cd claude-pet-windows
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

설치 스크립트가 하는 일 (여러 번 실행해도 안전):

1. 파일을 `%USERPROFILE%\.clawdex` 로 복사 (번들 펫 포함)
2. 훅 실행 파일 `clawdex-hook.exe` 컴파일 (Windows에 내장된 `csc.exe` 사용)
3. `~/.claude/settings.json` 에 훅 등록 — 기존 설정은 보존하고 `settings.json.clawdex-backup` 으로 백업
4. 바탕화면에 `Clawdex Pet` 바로가기 생성 (`-DesktopDir` 로 위치 지정 가능)
5. 펫 실행

제거: `~\.clawdex\uninstall.ps1` (훅과 바로가기를 제거합니다)

## 사용법

| 동작 | 방법 |
|---|---|
| 이동 | 펫을 드래그 |
| Claude 창 앞으로 | 펫 클릭 |
| 새 대화 / 보이스 | 호버 → 아래 알약의 펜 / 파형 버튼 |
| 크기 | 트레이 아이콘 클릭 → 슬라이더, 또는 펫 위에서 휠 |
| 펫 변경 | 펫 또는 트레이 우클릭 → 펫 변경 |
| 닫기 | 호버 → ✕ |
| 다시 켜기 | 바탕화면 `Clawdex Pet` 바로가기 (또는 새 Claude 세션 시작) |

명령줄 (`~\.clawdex\clawdex.ps1 -Command ...`): `wake`(기본) · `tuck` · `list` · `select -Arg <id>` · `size` · `new` · `voice`

## 설정

`~\.clawdex\config.json` (실행 중 자동 생성)

| 키 | 설명 |
|---|---|
| `pet` | 펫 id |
| `scale` | 크기 배율 (0.3 ~ 2.0) |
| `left`, `top` | 마지막 위치 |
| `newChatHotkey`, `voiceHotkey` | Claude 앱의 버튼을 못 찾았을 때만 쓰는 예비 단축키 (예: `"ctrl+shift+o"`). 비워 두면 사용 안 함 |

## 펫 추가

`pet.json` + `spritesheet.webp` 가 든 폴더를 `~\.clawdex\pets\<이름>\` 에 넣으면 됩니다.
포맷은 Codex 펫 규격(1536×1872, 192×208 셀 8열×9행, 투명 배경)을 따릅니다. 이 저장소의 `pets/` 에 번들된 펫은 설치 시 같이 복사됩니다.

## 동작 원리

```
Claude Code ─ hook ─▶ clawdex-hook.exe ─ 한 줄 이벤트 ─▶ ~\.clawdex\events.log ─▶ clawdex.ps1 (WPF 오버레이)
```

- 훅은 항상 즉시 종료(`exit 0`)하며 Claude Code를 기다리게 하지 않습니다.
- 오버레이는 WinRT 디코더로 WebP 알파를 보존해 읽고, 투명 창(`WS_EX_NOACTIVATE`)이라 포커스를 가져가지 않습니다.
- 새 대화 / 보이스 버튼은 UI Automation으로 Claude 앱의 실제 버튼을 찾아 누릅니다 (버튼 이름은 한국어·영어를 지원).

## 알려진 한계

- **보이스 버튼**: Claude 앱의 마이크 버튼에 실제 마우스 클릭을 보내는 데까지 확인했지만, 개발 PC의 Claude 앱에서 녹음 시작 표시는 확인하지 못했습니다. 앱 쪽 음성 입력 설정에 따라 동작하지 않을 수 있습니다.
- **새 대화 버튼**: Claude 앱의 "새로 생성" 버튼을 찾아 호출 가능한 것까지 확인했고, 실제 클릭 end-to-end는 미검증입니다.
- Claude 앱의 UI 문구가 바뀌면 버튼을 못 찾을 수 있습니다 (`clawdex.ps1` 의 `$UiaNewNames`, `$UiaVoiceNames` 에서 이름 목록을 수정).
- 펼침 알약의 아이콘은 Codex와 달리 연필 단일 아이콘입니다.
- 여러 모니터의 DPI가 서로 다를 때의 동작은 충분히 검증하지 못했습니다.

## 번들 펫과 저작권 안내

`pets/ram`, `pets/rem` 은 애니메이션 *Re:Zero* 의 캐릭터 람·렘을 모티프로 한 **팬 제작(inspired by) 펫**입니다. 캐릭터의 권리는 원저작권자에게 있으며, 이 저장소는 비상업적 팬 활동 목적으로만 포함합니다.
권리자의 요청이 있으면 해당 파일을 삭제합니다. 이 펫 이미지들은 아래의 코드 라이선스와 별개입니다.

## 크레딧

- 아이디어·펫 포맷·훅 매핑 참고: [danielkempe/clawdex](https://github.com/danielkempe/clawdex) (MIT)
- 펫 아틀라스 규격: Codex 펫 / [openai/skills hatch-pet](https://github.com/openai/skills)
