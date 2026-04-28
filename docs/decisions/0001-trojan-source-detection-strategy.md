---
number: 1
title: Trojan Source detection strategy
status: accepted
date: 2026-04-27
decision-makers:
  - toobuntu
---

# Trojan Source detection strategy

## Context and Problem Statement

CVE-2021-42574 ("Trojan Source") allows attackers to hide malicious code in
plain sight using Unicode bidirectional override and zero-width characters.
The technique was demonstrated by Boucher and Anderson at Cambridge in 2021
(see [trojansource.codes][trojansource]).

In March 2026 the technique was used at scale: the GlassWorm campaign
compromised at least 151 GitHub repositories plus npm packages and Open VSX
extensions between March 3-9, 2026 ([Aikido Security][aikido],
[Ars Technica][arstechnica], [Scientific American][sciam]). GlassWorm hides
its decoder loader using **Private Use Area (PUA) Unicode characters and
variation selectors** — codepoints that do not render visibly in editors,
terminals, or code review tools. The decoded payload then calls `eval()`
on a URL fetched from a Solana wallet (used as a dead-drop resolver).

The project must detect such characters before they enter the repository.
Detection must run both in the developer's pre-commit hook (fail fast) and
in CI (catch anything that bypassed the hook).

Some files legitimately need bidi controls (e.g. an i18n library, a Unicode
test fixture, an iCalendar writer that emits LRM around LTR times in an RTL
string). The detection strategy must allow narrowly-scoped, locally-visible
opt-out without weakening the default-deny policy.

## Decision Drivers

* Survives Apple's planned removal of bundled scripting language runtimes
  ([Apple Catalina release notes][apple-catalina])
* No new hard runtime dependency for contributors on macOS
* Two layers (hook + CI) with no exploitable detection gaps between them
* Inspects staged blob content, not working-tree files (the staged content
  is what enters the repository)
* Future-proof: new invisible characters added to Unicode in subsequent
  revisions should be caught without code changes
* Legitimate bidi use cases are accommodated via per-file opt-out that is
  visible at the point of use (not buried in a separate config file)
* Comments at the call site are minimal; rationale lives here

## Considered Options

* **`grep` in hook + `python3` Cf/Cc category check in CI** following [Red Hat
  RHSB-2021-007][redhat] in the hook with future-proof category-based detection in CI
* **`python3` in both hook and CI**, with the hook gated by `command -v
  python3` and a Homebrew install hint when missing
* **A single canonical scanner script** invoked from both layers (the
  approach ChatGPT's PR#8 review recommended)
* **`forbid-bidi-controls` from [`sirosen/texthooks`][texthooks]**
* **[`lirantal/anti-trojan-source`][anti-trojan]**

The opt-out mechanism was independently considered:

* **In-file `bidi-allow:` annotation, anywhere in the file** (chosen)
* **In-file annotation restricted to first N lines**
* **Repo-root config file** (e.g. `.bidi-allow`) listing exempt paths

## Decision Outcome

Chosen option: **`grep` in pre-commit + `python3` Unicode-category check in
CI**, with the hook's codepoint set following Red Hat's published
RHSB-2021-007 grep recommendation and CI flagging every character in
Unicode category Cf (Format) or Cc (Control) except a TAB/LF/CR allowlist
— the same approach used by Red Hat's own `find_unicode_control2.py`
script in its default mode. Both layers honor a per-file `bidi-allow:`
annotation for legitimate use cases.

### Pre-commit hook

The hook is `/bin/sh`. POSIX `printf '\NNN'` octal byte escapes construct
a UTF-8 byte sequence that BSD grep on macOS (and GNU grep on Linux)
interprets as a Unicode character class when run under
`LC_ALL=en_US.UTF-8`. No `bash` 4.2 `\u` escape and no `ksh93` $'\u' escape
is required, so the hook is independent of any specific shell version. The
resulting filter implements Red Hat's recommended terminal command:

> `grep -r $'[\u061C\u200E\u200F\u202A\u202B\u202C\u202D\u202E\u2066\u2067\u2068\u2069]' .`
> ([Red Hat RHSB-2021-007][redhat])

The hook extends Red Hat's set with three zero-width characters
(U+200B/200C/200D) and the UTF-8 BOM (U+FEFF; project policy requires
UTF-8 without BOM).

The grep one-liner is the right tool for the hook because grep regex has
no `\p{Cf}` notation — it can only operate on explicit codepoint sets.
This is also why Red Hat's bulletin published two artifacts: a Python
script (categories) and a grep one-liner (explicit codepoints).

### CI scanner

CI uses Python's stdlib `unicodedata.category()` to flag every character
in category **Cf (Format)** or **Cc (Control)**, with a small allowlist
for TAB/LF/CR. This is exactly what Red Hat's own
`find_unicode_control2.py` does in its default mode (no `--nonprint`
flag): `unicodedata.category(c) == 'Cf'`. We extend that with Cc to also
catch C0/C1 control characters, again excluding TAB/LF/CR. A similar
Cf/Cc-with-TAB/LF/CR-allowlist appears in
[`lirantal/anti-trojan-source`][anti-trojan]'s `unicode-categories.js`.

The Cf/Cc category approach in CI is **future-proof**: when Unicode adds
new invisible formatting characters in a future revision, the runner's
Python `unicodedata` reflects them automatically without code changes.
CI also enforces strict UTF-8 decoding so UTF-16/UTF-32 cannot bypass
the gate.

The two layers are intentionally complementary, not redundant:

* **Hook (fast, narrow, no Python):** Red Hat's published grep character
  set plus zero-width and BOM. POSIX shell only. Survives Apple's
  scripting-runtime purge. Citing Red Hat directly gives reviewers a
  stable, authoritative reference.
* **CI (thorough, broad, future-proof):** Cf/Cc category detection plus
  strict UTF-8 enforcement. Catches anything that slipped past the hook
  *and* anything Unicode adds in the future. Python is already present
  on GitHub-hosted runners.

### Per-file opt-out

A `bidi-allow: U+XXXX,U+YYYY` annotation **anywhere in the file** declares
which codepoints from the blocked set the file is allowed to contain.
Both layers honor it:

```go
// SPDX-License-Identifier: GPL-3.0-or-later
// bidi-allow: U+200E
package icalwriter

// rebuildHavdalaTitle constructs a SUMMARY where the LTR time is
// embedded in an RTL Hebrew base; LRM (U+200E) forces correct rendering
// in calendar apps that observe Unicode bidi.
```

Design properties:

* **Visible at the point of use** — a reviewer reading the file sees the
  exemption next to the code that needs it, not in a separate
  `.bidiallow` config file that nobody reads.
* **Anywhere in the file** — not restricted to a header window. Real
  files often start with multiple required headers (REUSE SPDX block,
  Ruby `# typed: true` / `# frozen_string_literal: true`, encoding
  declarations) that can push real code well past line 5. A line-count
  restriction would be brittle without a corresponding security gain:
  any new `bidi-allow:` line shows up in PR diff regardless of where
  it appears in the file, and is grep-able (`grep -r bidi-allow:`).
* **Scoped to one file** — opting out of a codepoint in one file does
  not silently allow it elsewhere.
* **Specific about codepoints** — `bidi-allow: U+200E` allows LRM only,
  not all bidi controls.
* **Survives copy-paste** — the annotation travels with the file.

The hook implements the opt-out by building a per-file grep pattern that
omits the allowed codepoints from the bracket expression. The CI scanner
parses the annotation in `parse_allow()` and skips the listed codepoints
during the Cf/Cc check.

#### File types that cannot carry an inline annotation

Almost every common text format supports comments — `#` (shell, Python,
Ruby, YAML, TOML, Makefile), `//` (C, Go, Rust, Swift, JavaScript), `<!--
-->` (HTML, XML, Markdown), `;` (INI), `--` (SQL, Lua), `%` (TeX, Erlang),
`/* */` (CSS, Java). The annotation parser is comment-syntax-agnostic: it
matches the literal token `bidi-allow:` regardless of what precedes it on
the line.

The known exception is **JSON** (the standard, not JSON5/JSONC), which
forbids comments. A JSON file legitimately requiring bidi controls in
*raw form* (rather than escaped as `\u202E` per the JSON spec) is
extraordinarily unlikely. No such file exists today across the
maintainer's repositories. Per YAGNI, no second mechanism is implemented
to handle this hypothetical. **If a JSON-class file ever needs raw bidi
controls in the future**, the right move at that time is a sidecar
allowlist file (`fixture.json` plus `fixture.json.bidi-allow` containing
just the codepoint list), preserving the locality property: the
exemption travels with the file in the same git tree node, can be
inspected next to it in code review, and does not require a repo-wide
config that hides exemptions from local readers. A repo-root config
file was specifically rejected for this reason — see "Pros and Cons of
the Options".

### Consequences

* Good, because the hook has zero new runtime dependencies and survives
  Apple's removal of bundled Python.
* Good, because CI's Cf/Cc category detection is automatically
  future-proof against new Unicode invisible characters.
* Good, because both layers' approaches are identifiable as Red Hat's
  published recommendations: the hook is RHSB-2021-007's grep one-liner,
  and CI is `find_unicode_control2.py`'s default-mode logic.
* Good, because legitimate bidi use cases (i18n libraries, Unicode test
  fixtures, RTL/LTR-mixing iCalendar writers) can opt in to specific
  codepoints with a one-line, locally-visible, codepoint-specific
  annotation that is not constrained by required-header pile-up at the
  top of the file.
* Bad, because contributors who edit the hook may not realize CI catches
  a superset of characters; the hook's comment block explicitly points
  to this ADR to prevent accidental "alignment" of the two lists.
* Bad, because **homoglyph attacks (CVE-2021-42694) are out of scope**.
  Homoglyphs are visible characters from non-ASCII scripts — Cyrillic
  'а' (U+0430) versus Latin 'a' (U+0061), for example. The
  codepoint-blocklist and Cf/Cc category approaches used here cannot
  catch them: they are category Lo or Ll (legitimate letters). Detection
  requires either an ASCII-only-identifier policy or comparison against
  the [Unicode CLDR confusables table][cldr] (~10,000 entries). A
  separate ADR will address homoglyph mitigation if the project adopts
  it. Note: the `lirantal/anti-trojan-source` README implies homoglyph
  support but its source code does not actually implement
  confusables-table comparison.
* Neutral, because the per-file opt-out widens the attack surface by the
  exact codepoints listed. The annotation is reviewable in PR diff and
  in source; reviewers must justify each new `bidi-allow:` line just
  as they would justify any other security-relevant change. There is no
  meaningful additional protection from a header-only restriction: an
  attacker who controls the file can place the annotation anywhere,
  including the top, so the restriction would only inconvenience
  legitimate use without raising the bar against attack.
* Neutral, because **PUA character ranges are not currently scanned**.
  GlassWorm's PUA payload smuggling could be detected by adding
  U+E000-U+F8FF, U+F0000-U+FFFFD, and U+100000-U+10FFFD to the CI
  scanner. PUA characters are category Co (Private Use), not Cf/Cc, so
  the category-based approach does not cover them. Tracked as a
  follow-up; see "More Information".
* Neutral, because comment-less file formats (JSON in particular) cannot
  carry an inline annotation. The use case is hypothetical for this
  project; a sidecar allowlist file is the documented escape hatch if
  it materializes.

### Confirmation

Behavioral tests in `spec/integration/precommit_unicode_spec.rb` exercise
both layers:

* The pre-commit hook is invoked via its shebang in a throwaway git repo
  with planted content; bidi, zero-width, BOM, opt-out, and clean files
  are each verified.
* The CI scanner's Python heredoc is extracted from `ci.yml` and run
  against planted directory trees verifying bidi, BOM, UTF-16,
  non-UTF-8, and opt-out behavior.
* Opt-out tests verify that (a) `bidi-allow: U+200E` plus a real LRM
  character passes; (b) codepoints not in the allow list still fail;
  and (c) annotations placed deep in the file (after a realistic
  pile-up of required headers) are honored.

Manual smoke tests are documented in `spec/manual/TESTING.md` under
"Unicode hardening".

## Pros and Cons of the Options

### `grep` in hook + `python3` Cf/Cc category check in CI (chosen)

* Good, hook is shell-only and survives Apple's scripting-runtime removal.
* Good, CI's Cf/Cc category detection is future-proof and follows Red
  Hat's own `find_unicode_control2.py` default mode — the canonical
  Python-based Trojan Source scanner.
* Good, character set in the hook is identical to Red Hat's published
  grep one-liner (citable to RHSB-2021-007).
* Good, per-file opt-out preserves locality and reviewability of
  exemptions.
* Bad, two character sets must be kept consistent; mitigated by ADR
  cross-references in both files.

### `python3` in both layers, gated on `command -v python3`

* Good, single character-set definition.
* Bad, hook silently no-ops on machines without Python — a worse outcome
  than the chosen option, which always runs.
* Bad, future macOS will not ship Python; the hook would degrade for an
  increasing fraction of contributors.

### Single canonical scanner script

* Good, no risk of detection-set divergence.
* Bad, requires either a Python script (same Apple-removal problem) or a
  shell script duplicating Python's Unicode handling.
* Bad, adds a third file to maintain when the two-layer split already
  achieves the security property with documented scope per layer.

### `forbid-bidi-controls` from `texthooks`

* Good, well-tested upstream implementation.
* Bad, adds a Python dependency and a `pre-commit` framework dependency
  for a project that uses raw `.githooks/`.
* Bad, project would lose control over the character set, the binary-skip
  semantics, and the per-file opt-out grammar.

### `lirantal/anti-trojan-source`

* Good, the **Cf/Cc category-with-TAB/LF/CR-allowlist pattern** in
  `src/unicode-categories.js` matches what Red Hat's
  `find_unicode_control2.py` does (the deeper precedent), and is
  congruent with our CI implementation.
* Good, well-documented project with a CLI that supports JSON output and
  line/column reporting.
* Bad, the README claims homoglyph support ("Glassworm" detection), but
  the source code does not actually implement confusables-table
  comparison. The "Glassworm" detection in
  [`src/constants.js`](https://github.com/lirantal/anti-trojan-source/blob/main/src/constants.js)
  is the same control/invisible-character list we already cover plus
  variation selectors — no homoglyph detection exists despite the
  project name.
* Bad, requires Node.js — same Apple-removal concern as Python, and Node
  is not present on macOS by default at all.
* Bad, depending on the tool would couple us to a project whose marketing
  outpaces its implementation. We can take the good idea (Cf/Cc category
  detection) — which itself originates with Red Hat — without taking the
  dependency.

### Opt-out: in-file annotation, anywhere in the file (chosen)

* Good, exemption travels with the file; a reviewer reading the source
  sees the annotation next to the code that needs it.
* Good, no separate parser is required to handle different comment
  syntaxes (`#`, `//`, `<!-- -->`, etc.) — the parser matches the literal
  token `bidi-allow:` regardless of what precedes it on the line.
* Good, "anywhere" is one rule with no edge cases. Real headers (REUSE
  SPDX, Ruby magic comments, encoding declarations) can push real code
  past any reasonable line-count limit; "anywhere" sidesteps the
  question entirely.
* Good, grep-able across the repo (`grep -r bidi-allow:`) for periodic
  audits of the total exemption surface.
* Bad, files in formats that forbid comments (standard JSON) cannot
  carry the annotation. Mitigated by the sidecar-file escape hatch
  documented above; not implemented until a real example arises.

### Opt-out: in-file annotation, restricted to first N lines

* Good, slightly cheaper to parse — only the head of the file is
  inspected.
* Bad, the parsing cost saving is negligible (the file is already being
  read in full for the actual character scan).
* Bad, brittle for real headers. REUSE adds 3 lines (SPDX-FileCopyrightText,
  blank, SPDX-License-Identifier). Ruby magic comments add 2 more
  (`# typed: true`, `# frozen_string_literal: true`). HTML/Markdown
  comment delimiters add 2. A 5-line limit is exhausted before the
  first line of project content; a 10-line limit is *probably* enough
  but introduces a magic number with no principled boundary.
* Bad, no real security benefit. The threat model is "an attacker hides
  the annotation deep in the file so reviewers don't see it." But the
  annotation appears in the PR diff regardless of position; a reviewer
  who misses it in a deep position would also miss it at the top
  (especially since the attack itself relies on invisible characters).
  The line-count restriction would impose a real cost on legitimate
  use without raising the bar against attack.

### Opt-out: repo-root config file (e.g. `.bidi-allow`)

* Good, works for files that cannot carry comments (JSON, certain binary
  fixtures interpreted as text).
* Good, exemptions are centrally listed and easy to audit at one path.
* Bad, **violates locality**. A reviewer reading a single file that
  contains bidi controls has no way to know it's exempted without
  cross-referencing a separate config. A copy of the file into another
  repo loses the exemption silently.
* Bad, two parsers required (in-file annotation grammar plus config
  file grammar) for one feature. Adds maintenance cost and surface area
  for inconsistency.
* Bad, the use case is hypothetical for this project — no file
  currently in scope (blackoutd, didan, homebrew-cask-tools) needs an
  opt-out that an inline annotation cannot satisfy.
* **Verdict per YAGNI**: deferred. If a real example arises, prefer a
  per-file sidecar (`fixture.json.bidi-allow`) over a repo-root config,
  to preserve locality.

## More Information

* [Red Hat Security Bulletin RHSB-2021-007][redhat] — original
  authoritative guidance. Source of the codepoint set used in the hook
  and of the Cf-category default mode used in CI (via
  `find_unicode_control2.py` distributed with the bulletin).
* [CVE-2021-42574 — Trojan Source][cve-trojan]
* [trojansource.codes][trojansource] — Boucher & Anderson's original
  proof-of-concept
* [`nickboucher/trojan-source`][trojan-poc] — PoC source
* [`nickboucher/bidi-viewer`][bidi-viewer] — visualizer for bidi attacks
* [Aikido Security: GlassWorm Returns][aikido] — March 2026 mass-scale
  campaign analysis
* [Ars Technica: Supply-chain attack using invisible code][arstechnica]
* [Scientific American: GlassWorm malware hides in invisible
  open-source code][sciam]
* [The Hacker News: GlassWorm Open VSX][thn-glassworm] — follow-on
  campaign coverage
* [Unicode General_Category property][ucd-gc] — definition of categories
  Cf and Cc used by `unicodedata.category()`
* [Apple Catalina release notes — scripting runtimes deprecation][apple-catalina]
* [`pre-commit/pre-commit-hooks` PR #685][pch-685] — rejected upstream
  proposal that motivated `forbid-bidi-controls`
* [`sirosen/texthooks`][texthooks] — `forbid-bidi-controls` reference
  implementation
* [`lirantal/anti-trojan-source`][anti-trojan] — independent Cf/Cc
  category-detection implementation in JavaScript
* [CVE-2021-42694 — Homoglyph attacks][cve-homo] — out of scope; addressable
  via [Unicode CLDR confusables][cldr]

[redhat]: https://access.redhat.com/security/vulnerabilities/RHSB-2021-007
[cve-trojan]: https://nvd.nist.gov/vuln/detail/CVE-2021-42574
[cve-homo]: https://nvd.nist.gov/vuln/detail/CVE-2021-42694
[trojansource]: https://trojansource.codes/
[trojan-poc]: https://github.com/nickboucher/trojan-source
[bidi-viewer]: https://github.com/nickboucher/bidi-viewer
[aikido]: https://www.aikido.dev/blog/glassworm-returns-unicode-attack-github-npm-vscode
[arstechnica]: https://arstechnica.com/security/2026/03/supply-chain-attack-using-invisible-code-hits-github-and-other-repositories/
[sciam]: https://www.scientificamerican.com/article/glassworm-malware-hides-in-invisible-open-source-code/
[thn-glassworm]: https://thehackernews.com/2026/03/glassworm-supply-chain-attack-abuses-72.html
[ucd-gc]: https://www.unicode.org/reports/tr44/#General_Category_Values
[apple-catalina]: https://developer.apple.com/documentation/macos-release-notes/macos-catalina-10_15-release-notes#Scripting-Language-Runtimes
[pch-685]: https://github.com/pre-commit/pre-commit-hooks/pull/685#issuecomment-2395140382
[texthooks]: https://github.com/sirosen/texthooks/blob/main/src/texthooks/forbid_bidi_controls.py
[anti-trojan]: https://github.com/lirantal/anti-trojan-source
[cldr]: https://www.unicode.org/Public/security/latest/confusables.txt
