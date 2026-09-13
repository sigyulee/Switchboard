# Switchboard

Connecting agents with agents.

[English](../README.md)

Switchboard는 Mac의 음성 Agent와 통화 앱을 연결합니다. 양쪽 목소리를 들으며
세션을 녹음하고, 기기에서 처리되는 실시간 전사와 번역으로 대화를 확인할 수 있습니다.

## 기능

- Agent 앱과 통화 앱 선택
- 이름을 붙인 세션의 시작, 일시정지, 재개, 저장
- 녹음과 전사 개별 제어
- 통화 상대와 Agent의 파형 및 청취 음량 조절
- 원문 아래 번역이 표시되는 실시간 전사
- 녹음 재생, 검색, 전사 시점으로 이동
- M4A, 화자별 WAV, 전사 TXT 내보내기
- 헤드폰 청취 및 내장 스피커 대체 옵션
- 한국어·영어 인터페이스

## 요구 사항

- macOS 26 이상을 실행하는 Apple Silicon Mac
- Swift 6.2 이상, macOS SDK 26 이상
- Python 3
- 마이크와 스피커를 선택할 수 있는 통화 앱

전사와 번역에 사용할 수 있는 언어는 Mac에서 지원하는 모델에 따라 달라집니다.
필요한 모델은 세션의 언어 설정에서 다운로드할 수 있습니다.

## 빌드

```sh
bash scripts/check.sh
bash scripts/build-app.sh release
```

앱은 `build/Switchboard.app`에 생성됩니다. DMG 생성:

```sh
bash scripts/build-dmg.sh
```

## 연결

1. Switchboard를 열고 사용할 언어를 선택합니다.
2. 설정에서 Agent 앱과 통화 앱을 선택합니다.
3. 오디오 장치를 설치하고 마이크·시스템 오디오 접근을 허용합니다.
4. 두 앱에서 다음 장치를 선택합니다.

| 앱 | 설정 | 장치 |
| --- | --- | --- |
| Agent | 마이크 | Switchboard → Agent |
| 통화 앱 | 스피커 | Caller → Switchboard |
| 통화 앱 | 마이크 | Agent → Caller |

Agent 앱에서 **기본값(Default)**만 선택할 수 있다면 그대로 두세요.
세션을 시작하면 Switchboard가 Mac의 입력 장치를 선택합니다.

청취 장치를 선택하고 세션 이름을 입력한 뒤 **시작**을 누르면 녹음이 시작됩니다.
녹음과 전사는 각각 켜고 끌 수 있습니다.

**일시정지**는 음성 전달과 녹음, 전사를 함께 멈춥니다. **재개**하면 기존 선택이
복원됩니다. 일시정지한 시간은 저장된 음성에 무음으로 남습니다.

**세션 종료 → 저장**에서 파일 이름과 저장 위치를 선택합니다. 라이브러리에는 기본
폴더와 설정에서 추가한 폴더가 표시됩니다. 세션 파일을 직접 열 수도 있습니다.

[설치](LOCAL-INSTALL.md) · [구조](ARCHITECTURE.md) · [테스트](TESTING.md) ·
[버전 관리](VERSIONING.md) · [기여](../CONTRIBUTING.md)
