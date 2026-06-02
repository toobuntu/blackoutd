---
# SPDX-FileCopyrightText: Copyright 2026 Todd Schulman
#
# SPDX-License-Identifier: GPL-3.0-or-later

number: 6
title: Run the RSpec suite under Homebrew's portable Ruby
status: accepted
date: 2026-06-01
decision-makers:
  - toobuntu
---

# Run the RSpec suite under Homebrew's portable Ruby

## Context and Problem Statement

blackoutd's behavioral tests (`spec/integration/`) exercise the
pre-commit hook and the CI Unicode scanner in RSpec. Running them
needs a Ruby and a Bundler-managed gemset. The daemon itself is
Objective-C and ships no Ruby, so this is a dev/test-only toolchain
question.

macOS still provides a system Ruby at `/usr/bin/ruby` (2.6,
deprecated; Apple has signaled removal). Installing gems against it
writes to `/Library/Ruby/Gems/` — a root-owned system path that
needs `sudo`, is wiped by macOS updates, and pollutes a runtime
shared by anything else invoking system Ruby. The question is which
Ruby, and which gem-install strategy, give a reproducible suite both
locally and in CI without touching the system.

This decision was prompted in part by an incident: before
`.bundle/config` was in place, RSpec was installed into system Ruby
(a plain `gem install`), polluting `/Library/Ruby/Gems/` and
requiring manual cleanup. The cleanup recipe and the "never
`sudo gem install`" rule now live in `docs/agent-principles.md`
("Bundler hygiene"); this ADR records the toolchain choice that makes
the mistake hard to repeat.

## Decision Drivers

* Local and CI must run the same Ruby, so version skew can't produce
  green-locally / red-in-CI gaps.
* Gems must never land in `/Library/Ruby/Gems/`: no `sudo`, no system
  pollution, and survival across macOS updates.
* Avoid adding a per-contributor version manager (rbenv, rvm,
  chruby) if the toolchain can lean on something a macOS + Homebrew
  contributor already has.
* Minimal setup on a freshly bootstrapped Mac.
* Follow the project's "don't depend on fragile system runtimes"
  ethos — the same reasoning that keeps the hook `#!/bin/sh` with no
  Python (see ADR 0001).

## Considered Options

* System Ruby 2.6 (`/usr/bin/ruby`) with Bundler
* A Ruby version manager (rbenv, rvm, or chruby + ruby-install)
* Homebrew's portable Ruby (the vendored Ruby that backs `brew`),
  with project-local gems via `.bundle/config`

## Decision Outcome

The suite runs under Homebrew's portable Ruby with gems installed
project-locally. `.bundle/config` pins `BUNDLE_PATH: vendor/bundle`
and `BUNDLE_DISABLE_SHARED_GEMS: true`, so `bundle install` writes to
`./vendor/bundle/` (gitignored). The `test` make target wraps the
exact invocation:

```sh
env -P"$(brew --repository)/Library/Homebrew/vendor/portable-ruby/current/bin:$PATH" bundle exec rspec
```

CI's `spec` job runs the same suite via `Homebrew/actions/setup-ruby`
(`portable-ruby: true`, `bundler-cache: true`), so the runner uses
the same Ruby and the same project-local gem layout. System Ruby 2.6
remains only as an unsupported fallback.

## Consequences

* Good, because portable Ruby ships with Homebrew, which every
  contributor already has — no new version-manager dependency and no
  extra bootstrap step.
* Good, because local (`make test`) and CI (`setup-ruby` with
  `portable-ruby: true`) run the same Ruby and the same
  `vendor/bundle` layout, shrinking "works on my machine" gaps.
* Good, because gems install to `./vendor/bundle/`, never
  `/Library/Ruby/Gems/`: no `sudo`, no system pollution, and a macOS
  update that resets system Ruby cannot break the suite.
* Good, because `make test` hides the `env -P …:$PATH bundle exec`
  invocation, so contributors neither memorize PATH gymnastics nor
  accidentally fall back to system Ruby.
* Bad, because the Ruby patch version floats with Homebrew's
  portable-ruby formula — a `brew update` can bump it. `Gemfile.lock`
  pins the gems and CI exercises the same Ruby, which bounds the
  blast radius, but the Ruby itself is not pinned to a patch.
* Bad, because it couples the test toolchain to Homebrew being
  installed. Acceptable: the project is already macOS-and-Homebrew
  centric and CI is Homebrew-based, so this adds no reach the project
  did not already assume.
* Neutral, because system Ruby still exists and a bare
  `bundle exec rspec` would run there if invoked outside the wrapper;
  `make test` and CI are the supported paths, not a hard lockout.

## More Information

The Bundler-hygiene rule set — the `.bundle/config` rationale, the
"never `sudo gem install`" prohibition, and the system-gem cleanup
recipe (`gem list --local | grep …`; `sudo gem uninstall …`;
`bundle install`) — lives in `docs/agent-principles.md`. Contributor
setup (the one-time `bundle install` under portable Ruby, then
`make test`) is documented in `CONTRIBUTING.md` ("Tests").

The portable-Ruby and RSpec version pair was validated against
Homebrew's own `Gemfile.lock`, which pins the same pair this project
uses.

If a second toobuntu repository adopts this toolchain, promote this
ADR (or a generalized form) to the shared `repo-foundation` standards
rather than copying it per repo.
