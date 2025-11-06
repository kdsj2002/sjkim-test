"""Tests for snake game"""

import sys
from pathlib import Path

# Add src to path for imports
sys.path.insert(0, str(Path(__file__).parent.parent / "src"))

from snake_game import SnakeGame, Direction


def test_snake_game_initialization():
    """Test snake game initialization"""
    game = SnakeGame(40, 20)

    assert game.width == 40
    assert game.height == 20
    assert game.score == 0
    assert game.game_over is False
    assert len(game.snake) == 3
    assert game.direction == Direction.RIGHT


def test_snake_movement():
    """Test snake movement"""
    game = SnakeGame(40, 20)
    initial_head = game.snake[0]

    game.move()

    new_head = game.snake[0]
    # Moving right should increase x coordinate
    assert new_head[1] == initial_head[1] + 1
    assert new_head[0] == initial_head[0]


def test_direction_change():
    """Test direction change"""
    game = SnakeGame(40, 20)

    # Can change from RIGHT to UP
    game.change_direction(Direction.UP)
    assert game.direction == Direction.UP

    # Cannot change to opposite direction (DOWN)
    game.change_direction(Direction.DOWN)
    assert game.direction == Direction.UP  # Should remain UP


def test_food_eating():
    """Test eating food increases score and snake length"""
    game = SnakeGame(40, 20)

    # Place food right in front of snake
    head_y, head_x = game.snake[0]
    game.food = (head_y, head_x + 1)

    initial_length = len(game.snake)
    initial_score = game.score

    game.move()

    assert game.score == initial_score + 10
    assert len(game.snake) == initial_length + 1


def test_wall_collision():
    """Test wall collision ends game"""
    game = SnakeGame(40, 20)

    # Move snake to top wall
    game.snake = [(1, 20), (2, 20), (3, 20)]
    game.direction = Direction.UP

    game.move()

    assert game.game_over is True


def test_self_collision():
    """Test self collision ends game"""
    game = SnakeGame(40, 20)

    # Create a scenario where snake will hit itself
    # Snake in a position where it will collide
    game.snake = [(10, 10), (10, 11), (11, 11), (11, 10)]
    game.direction = Direction.DOWN

    game.move()

    assert game.game_over is True


def test_get_state():
    """Test get_state returns correct game state"""
    game = SnakeGame(40, 20)

    state = game.get_state()

    assert 'snake' in state
    assert 'food' in state
    assert 'score' in state
    assert 'game_over' in state
    assert state['snake'] == game.snake
    assert state['food'] == game.food
    assert state['score'] == game.score
    assert state['game_over'] == game.game_over
