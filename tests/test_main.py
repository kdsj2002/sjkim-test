"""Tests for main module"""

import sys
from pathlib import Path

# Add src to path for imports
sys.path.insert(0, str(Path(__file__).parent.parent / "src"))

from main import main


def test_main(capsys):
    """Test main function"""
    main()
    captured = capsys.readouterr()
    assert "Hello, sjkim-test!" in captured.out
    assert "성공적으로 실행" in captured.out
