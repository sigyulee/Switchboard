# Switchboard

[English](../README.md)

Chrome의 음성 Agent와 macOS Phone을 연결합니다. 양쪽 목소리를 함께 듣고,
각각의 청취 음량을 조절하며 대화를 녹음할 수 있습니다.

## 기능

- Chrome과 Phone 사이의 양방향 오디오 연결
- 통화 상대와 Agent의 파형 및 개별 청취 음량
- 녹음, 재생, 탐색, 검색, 이름 변경
- M4A 합본과 음성별 WAV 내보내기
- 청취 장치 연결 해제 시 내장 스피커로 대체하는 옵션
- 첫 실행과 설정에서 선택할 수 있는 영어·한국어 UI

## 요구 사항

- macOS 27 이상을 실행하는 Apple Silicon Mac
- Swift 6.4 호환 도구와 macOS SDK
- Python 3

## 빌드

```sh
bash scripts/check.sh
bash scripts/build-app.sh release
```

앱은 `build/Switchboard.app`에 생성됩니다. DMG를 만들려면 다음 명령을 실행합니다.

```sh
bash scripts/build-dmg.sh
```

## 연결

1. Switchboard를 실행하고 언어를 선택합니다.
2. 오디오 장치 두 개를 설치하고 마이크·시스템 오디오 접근을 허용합니다.
3. Phone의 스피커는 **Phone → Agent**, 마이크는 **Chrome → Phone**으로 선택합니다.
4. Chrome의 Agent 마이크는 **Default**로 둡니다.
5. Switchboard에서 청취 장치를 선택합니다.

**녹음**을 눌러 시작하고 **중지**를 눌러 마칩니다.
저장한 대화는 **녹음** 탭에서 재생하거나 내보낼 수 있습니다.
