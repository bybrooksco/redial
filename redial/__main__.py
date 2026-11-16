"""python3 -m redial: run the daemon."""

from .cli import main

try:
    main()
except KeyboardInterrupt:
    pass
