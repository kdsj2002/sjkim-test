"""Snake Game - 뱀꼬리 잡기 게임"""

import curses
import random
from enum import Enum
from typing import List, Tuple


class Direction(Enum):
    """방향을 나타내는 열거형"""
    UP = (-1, 0)
    DOWN = (1, 0)
    LEFT = (0, -1)
    RIGHT = (0, 1)


class SnakeGame:
    """뱀꼬리 잡기 게임 클래스"""

    def __init__(self, width: int = 40, height: int = 20):
        """
        게임 초기화

        Args:
            width: 게임 화면 너비
            height: 게임 화면 높이
        """
        self.width = width
        self.height = height
        self.score = 0
        self.game_over = False

        # 뱀 초기 위치 (중앙)
        start_y = height // 2
        start_x = width // 2
        self.snake: List[Tuple[int, int]] = [
            (start_y, start_x),
            (start_y, start_x - 1),
            (start_y, start_x - 2)
        ]

        self.direction = Direction.RIGHT
        self.food = self._generate_food()

    def _generate_food(self) -> Tuple[int, int]:
        """먹이를 랜덤한 위치에 생성"""
        while True:
            food = (
                random.randint(1, self.height - 2),
                random.randint(1, self.width - 2)
            )
            if food not in self.snake:
                return food

    def change_direction(self, new_direction: Direction) -> None:
        """
        방향 변경 (반대 방향으로는 갈 수 없음)

        Args:
            new_direction: 새로운 방향
        """
        # 반대 방향으로는 갈 수 없음
        opposite_directions = {
            Direction.UP: Direction.DOWN,
            Direction.DOWN: Direction.UP,
            Direction.LEFT: Direction.RIGHT,
            Direction.RIGHT: Direction.LEFT
        }

        if new_direction != opposite_directions.get(self.direction):
            self.direction = new_direction

    def move(self) -> None:
        """뱀을 한 칸 이동"""
        if self.game_over:
            return

        # 머리 위치 계산
        head_y, head_x = self.snake[0]
        dy, dx = self.direction.value
        new_head = (head_y + dy, head_x + dx)

        # 벽 충돌 체크
        if (new_head[0] <= 0 or new_head[0] >= self.height - 1 or
            new_head[1] <= 0 or new_head[1] >= self.width - 1):
            self.game_over = True
            return

        # 자기 몸 충돌 체크
        if new_head in self.snake:
            self.game_over = True
            return

        # 뱀 이동
        self.snake.insert(0, new_head)

        # 먹이를 먹었는지 체크
        if new_head == self.food:
            self.score += 10
            self.food = self._generate_food()
        else:
            # 먹이를 먹지 않았으면 꼬리 제거
            self.snake.pop()

    def get_state(self) -> dict:
        """현재 게임 상태 반환"""
        return {
            'snake': self.snake,
            'food': self.food,
            'score': self.score,
            'game_over': self.game_over
        }


def draw_game(stdscr, game: SnakeGame) -> None:
    """
    게임 화면 그리기

    Args:
        stdscr: curses 화면 객체
        game: SnakeGame 인스턴스
    """
    stdscr.clear()

    # 테두리 그리기
    for i in range(game.width):
        stdscr.addstr(0, i, "═")
        stdscr.addstr(game.height - 1, i, "═")
    for i in range(game.height):
        stdscr.addstr(i, 0, "║")
        stdscr.addstr(i, game.width - 1, "║")

    # 코너
    stdscr.addstr(0, 0, "╔")
    stdscr.addstr(0, game.width - 1, "╗")
    stdscr.addstr(game.height - 1, 0, "╚")
    stdscr.addstr(game.height - 1, game.width - 1, "╝")

    # 뱀 그리기
    for i, (y, x) in enumerate(game.snake):
        if i == 0:
            stdscr.addstr(y, x, "●")  # 머리
        else:
            stdscr.addstr(y, x, "○")  # 몸통

    # 먹이 그리기
    food_y, food_x = game.food
    stdscr.addstr(food_y, food_x, "★")

    # 점수 표시
    stdscr.addstr(game.height, 2, f"점수: {game.score}")
    stdscr.addstr(game.height + 1, 2, "방향키로 이동 | q: 종료")

    if game.game_over:
        msg = "게임 오버! 아무 키나 누르면 종료됩니다."
        stdscr.addstr(game.height // 2, (game.width - len(msg)) // 2, msg)

    stdscr.refresh()


def main(stdscr) -> None:
    """
    게임 메인 루프

    Args:
        stdscr: curses 화면 객체
    """
    # curses 설정
    curses.curs_set(0)  # 커서 숨기기
    stdscr.nodelay(1)   # non-blocking 입력
    stdscr.timeout(100)  # 100ms 대기

    game = SnakeGame(40, 20)

    while True:
        draw_game(stdscr, game)

        # 키 입력 처리
        key = stdscr.getch()

        if key == ord('q'):
            break
        elif key == curses.KEY_UP:
            game.change_direction(Direction.UP)
        elif key == curses.KEY_DOWN:
            game.change_direction(Direction.DOWN)
        elif key == curses.KEY_LEFT:
            game.change_direction(Direction.LEFT)
        elif key == curses.KEY_RIGHT:
            game.change_direction(Direction.RIGHT)

        if game.game_over:
            stdscr.nodelay(0)  # blocking 모드로 전환
            stdscr.getch()     # 아무 키나 누르기 대기
            break

        game.move()


def start_game() -> None:
    """게임 시작"""
    try:
        curses.wrapper(main)
    except KeyboardInterrupt:
        pass

    print("게임을 종료합니다. 감사합니다!")


if __name__ == "__main__":
    start_game()
