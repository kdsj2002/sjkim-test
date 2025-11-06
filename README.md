# sjkim-test

Python 게임 프로젝트

## 설명

이 프로젝트는 Python 기반의 뱀꼬리 잡기 게임입니다.

## 게임 소개

**뱀꼬리 잡기 (Snake Game)**는 클래식한 아케이드 게임입니다.
- 방향키로 뱀을 조종하여 먹이(★)를 먹습니다
- 먹이를 먹을수록 뱀이 길어지고 점수가 올라갑니다
- 벽이나 자신의 몸에 부딪히면 게임 오버!
- 최고 점수를 목표로 도전하세요!

## 설치 방법

```bash
# 가상환경 생성
python -m venv venv

# 가상환경 활성화 (Linux/Mac)
source venv/bin/activate

# 가상환경 활성화 (Windows)
venv\Scripts\activate

# 의존성 설치
pip install -r requirements.txt
```

## 게임 실행 방법

```bash
# 뱀꼬리 잡기 게임 시작
python play_snake.py

# 또는 직접 모듈 실행
python src/snake_game.py
```

## 게임 조작법

- **↑ (위 방향키)**: 뱀을 위로 이동
- **↓ (아래 방향키)**: 뱀을 아래로 이동
- **← (왼쪽 방향키)**: 뱀을 왼쪽으로 이동
- **→ (오른쪽 방향키)**: 뱀을 오른쪽으로 이동
- **q**: 게임 종료

## 기타 예제

```bash
# Hello World 예제 실행
python src/main.py
```

## 프로젝트 구조

```
sjkim-test/
├── src/
│   ├── __init__.py
│   ├── main.py          # Hello World 예제
│   └── snake_game.py    # 뱀꼬리 잡기 게임
├── tests/
│   ├── __init__.py
│   └── test_main.py
├── play_snake.py        # 게임 실행 스크립트
├── requirements.txt
├── README.md
└── .gitignore
```

## 라이센스

MIT License
