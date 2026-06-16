"""Ensure the bot package is importable when running pytest from any cwd."""
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
