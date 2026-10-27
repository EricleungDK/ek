#!/usr/bin/env python3
"""mech-review: mechanical PR checks (contract JSON). Run `python3 -I scripts/mech-review.py --help`."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # -I drops the script dir from sys.path

from mech_review.cli import main  # noqa: E402

if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
