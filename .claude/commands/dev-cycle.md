---
description: Build and reload the daemon for development iteration
---

Run a fast development build cycle for blackoutd:

1. `make clean && make` — clean rebuild from source
2. `make dev` — bootout the running agent and bootstrap with `build/blackoutd`

Stop and report verbatim if any step fails. Do not modify source files
to clear errors unless I explicitly ask.

If both steps succeed, run `blackoutd status` and report its output.

Do not commit anything.
