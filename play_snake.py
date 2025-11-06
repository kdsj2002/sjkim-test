#!/usr/bin/env python3
"""뱀꼬리 잡기 게임 실행 스크립트"""

import sys
from pathlib import Path

# src 디렉토리를 path에 추가
sys.path.insert(0, str(Path(__file__).parent / "src"))

from snake_game import start_game

if __name__ == "__main__":
    print("=" * 50)
    print("뱀꼬리 잡기 게임에 오신 것을 환영합니다!")
    print("=" * 50)
    print()
    print("게임 방법:")
    print("  - 방향키로 뱀을 조종합니다")
    print("  - ★(별)을 먹으면 점수가 올라갑니다")
    print("  - 벽이나 자기 몸에 부딪히면 게임 오버!")
    print("  - q 키를 누르면 게임을 종료합니다")
    print()
    print("준비되셨으면 엔터를 누르세요...")
    input()

    start_game()
