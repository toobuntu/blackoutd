# SPDX-FileCopyrightText: Copyright 2026 Todd Schulman
#
# SPDX-License-Identifier: GPL-3.0-or-later

# Disable REUSE linting to prevent SPDX-like substrings in test fixtures
# from being misinterpreted as malformed license metadata.
# REUSE-IgnoreStart

require "fileutils"
require "open3"
require "tmpdir"

# Behavioral tests for the supply-chain hardening checks added in v0.2:
#
#   - .githooks/pre-commit invisible-Unicode check (RedHat grep approach)
#   - .github/workflows/ci.yml lint-unicode Python scanner
#
# Both layers also support a per-file `bidi-allow:` opt-out annotation
# placed anywhere in the file.
#
# The hook is exercised by setting up a throwaway git repository, staging
# planted files, and invoking the hook directly from the source tree. The
# CI scanner is exercised by extracting the embedded Python heredoc from
# ci.yml and running it against a planted directory tree. This keeps the
# tests self-contained and avoids requiring the actual GitHub Actions
# runtime.

REPO_ROOT = File.expand_path("../../..", __FILE__)
HOOK_PATH = File.join(REPO_ROOT, ".githooks", "pre-commit")
LINT_PERMS_PATH = File.join(REPO_ROOT, "scripts", "lint-perms.sh")
CI_YML_PATH = File.join(REPO_ROOT, ".github", "workflows", "ci.yml")

# Bidi/zero-width/BOM codepoints that must trigger the check.
BIDI_OVERRIDE_RLO = "\u202E"  # right-to-left override
BIDI_ISOLATE_RLI  = "\u2067"  # right-to-left isolate
ZERO_WIDTH_SPACE  = "\u200B"
ARABIC_LETTER_MK  = "\u061C"
LRM               = "\u200E"  # left-to-right mark (legitimate use case)
RLM               = "\u200F"  # right-to-left mark (legitimate use case)
UTF8_BOM          = "\uFEFF"

# Codepoints that must NOT trigger the check (legitimate Unicode).
LATIN_E_GRAVE     = "\u00E8"  # è
GREEK_ALPHA       = "\u03B1"  # α
EM_DASH           = "\u2014"  # —

module HookSpecHelpers
  # Creates a temp git repo, configures the local pre-commit hook,
  # writes the given files, stages them, and yields the working dir.
  #
  # scripts/lint-perms.sh is also copied in (and staged 0755) because
  # the hook's perms check trust guard requires its presence. Without
  # this, the hook would error out before reaching the unicode check
  # the rest of the suite is testing.
  def with_git_repo(files)
    Dir.mktmpdir("blackoutd-hook-test-") do |dir|
      Dir.chdir(dir) do
        run!("git", "init", "--quiet", "--initial-branch=feature/test")
        run!("git", "config", "user.email", "test@example.invalid")
        run!("git", "config", "user.name",  "Test")
        # Copy the project's hook into this throwaway repo.
        FileUtils.mkdir_p(".githooks")
        FileUtils.cp(HOOK_PATH, ".githooks/pre-commit")
        File.chmod(0o755, ".githooks/pre-commit")
        run!("git", "config", "core.hooksPath", ".githooks")
        # Copy the perms-check script so the hook's trust guard passes.
        FileUtils.mkdir_p("scripts")
        FileUtils.cp(LINT_PERMS_PATH, "scripts/lint-perms.sh")
        File.chmod(0o755, "scripts/lint-perms.sh")
        run!("git", "add", "scripts/lint-perms.sh")
        run!("git", "update-index", "--chmod=+x", "scripts/lint-perms.sh")
        # Write planted content and stage.
        files.each do |relpath, content|
          FileUtils.mkdir_p(File.dirname(relpath))
          File.binwrite(relpath, content)
          run!("git", "add", relpath)
        end
        yield dir
      end
    end
  end

  # Runs the hook directly (not through `git commit`) so the test can
  # observe its exit status and stderr without committing.
  #
  # BLACKOUTD_SKIP_REUSE_LINT=1: these specs target the hook's Unicode
  # scanner, not its REUSE gate. The throwaway repos carry no SPDX
  # headers, so with reuse installed the REUSE stanza would reject every
  # fixture and mask the check under test. The REUSE path has its own
  # coverage (precommit_reuse_spec.rb and the lint-reuse CI job).
  def run_hook
    Open3.capture3({ "BLACKOUTD_SKIP_REUSE_LINT" => "1", "GIT_DIR" => ".git", "GIT_INDEX_FILE" => ".git/index" },
                   "./.githooks/pre-commit")
  end

  def run!(*cmd)
    out, err, status = Open3.capture3(*cmd)
    raise "command failed: #{cmd.inspect}\nstdout: #{out}\nstderr: #{err}" unless status.success?
    [out, err]
  end
end

RSpec.describe "pre-commit hook: invisible Unicode detection" do
  include HookSpecHelpers

  it "rejects a file containing a bidi override character" do
    with_git_repo("evil.c" => "int main(){#{BIDI_OVERRIDE_RLO}return 0;}\n") do
      _stdout, stderr, status = run_hook
      expect(status.success?).to eq(false), "hook should fail; stderr=#{stderr.inspect}"
      expect(stderr).to include("evil.c")
      expect(stderr).to match(/invisible Unicode/i)
    end
  end

  it "rejects a file containing a bidi isolate character" do
    with_git_repo("evil.txt" => "hello#{BIDI_ISOLATE_RLI}world") do
      _stdout, stderr, status = run_hook
      expect(status.success?).to eq(false)
      expect(stderr).to include("evil.txt")
    end
  end

  it "rejects a file containing a zero-width space" do
    with_git_repo("zwsp.md" => "Look#{ZERO_WIDTH_SPACE}here\n") do
      _stdout, stderr, status = run_hook
      expect(status.success?).to eq(false)
      expect(stderr).to include("zwsp.md")
    end
  end

  it "rejects a file containing an Arabic letter mark" do
    with_git_repo("alm.txt" => "x#{ARABIC_LETTER_MK}y") do
      _stdout, stderr, status = run_hook
      expect(status.success?).to eq(false)
      expect(stderr).to include("alm.txt")
    end
  end

  it "rejects a file beginning with a UTF-8 BOM" do
    with_git_repo("bom.txt" => "#{UTF8_BOM}content\n") do
      _stdout, stderr, status = run_hook
      expect(status.success?).to eq(false)
      expect(stderr).to include("bom.txt")
    end
  end

  it "passes a clean ASCII file" do
    with_git_repo("clean.c" => "int main(void) { return 0; }\n") do
      _stdout, stderr, status = run_hook
      expect(status.success?).to eq(true), "hook should pass; stderr=#{stderr.inspect}"
    end
  end

  it "passes a file containing legitimate non-ASCII Unicode" do
    text = "café #{LATIN_E_GRAVE} #{GREEK_ALPHA} dash #{EM_DASH}\n"
    with_git_repo("ok.md" => text) do
      _stdout, stderr, status = run_hook
      expect(status.success?).to eq(true), "stderr=#{stderr.inspect}"
    end
  end

  it "skips binary blobs (NUL bytes present)" do
    # A blob with NUL bytes that also happens to contain the byte sequence
    # for U+202E. grep --binary-files=without-match must skip it.
    binary = "PNG\0\0\0".dup.force_encoding(Encoding::ASCII_8BIT)
    binary << "\xE2\x80\xAE".dup.force_encoding(Encoding::ASCII_8BIT)
    binary << "\0trailing".dup.force_encoding(Encoding::ASCII_8BIT)
    with_git_repo("blob.bin" => binary) do
      _stdout, stderr, status = run_hook
      expect(status.success?).to eq(true), "stderr=#{stderr.inspect}"
    end
  end

  it "rejects only the offending file when multiple are staged" do
    files = {
      "ok.txt"   => "fine\n",
      "evil.txt" => "bad#{BIDI_OVERRIDE_RLO}\n",
    }
    with_git_repo(files) do
      _stdout, stderr, status = run_hook
      expect(status.success?).to eq(false)
      expect(stderr).to include("evil.txt")
      expect(stderr).not_to include("ok.txt")
    end
  end

  describe "per-file opt-out via bidi-allow annotation" do
    it "passes a file with bidi-allow: U+200E and a real LRM character" do
      content = "// bidi-allow: U+200E\n" \
                "package main\n" \
                "var rtl = \"#{LRM}time\"\n"
      with_git_repo("rtl.go" => content) do
        _stdout, stderr, status = run_hook
        expect(status.success?).to eq(true), "stderr=#{stderr.inspect}"
      end
    end

    it "passes a file allowing two codepoints" do
      content = "// bidi-allow: U+200E,U+200F\n" \
                "var s = \"#{LRM}#{RLM}\"\n"
      with_git_repo("rtl.go" => content) do
        _stdout, stderr, status = run_hook
        expect(status.success?).to eq(true), "stderr=#{stderr.inspect}"
      end
    end

    it "still rejects codepoints not in the allow list" do
      # U+200E is allowed but U+202E (RLO) is not.
      content = "// bidi-allow: U+200E\n" \
                "// hidden: #{BIDI_OVERRIDE_RLO} payload\n"
      with_git_repo("evil.go" => content) do
        _stdout, stderr, status = run_hook
        expect(status.success?).to eq(false), "should fail; stderr=#{stderr.inspect}"
        expect(stderr).to include("evil.go")
      end
    end

    it "honors annotations placed deep in the file" do
      # Headers (REUSE SPDX, magic comments, encoding decls) plus a
      # blank line and the SPDX block can easily push real code past
      # line 5, so the annotation must work anywhere in the file.
      content = "# typed: true\n" \
                "# frozen_string_literal: true\n" \
                "\n" \
                "# SPDX-FileCopyrightText: Copyright 2026 Test\n" \
                "#\n" \
                "# SPDX-License-Identifier: GPL-3.0-or-later\n" \
                "\n" \
                "# bidi-allow: U+200E\n" \
                "x = \"#{LRM}content\"\n"
      with_git_repo("deep.rb" => content) do
        _stdout, stderr, status = run_hook
        expect(status.success?).to eq(true), "stderr=#{stderr.inspect}"
      end
    end
  end
end

RSpec.describe "CI lint-unicode scanner" do
  # Extract the Python heredoc body from ci.yml so the test runs the same
  # logic CI would run, without coupling to the workflow harness.
  #
  # The regex assumes the YAML pipe block in ci.yml indents each line by
  # 10 spaces (the current ci.yml structure). If the indentation changes,
  # the post-extraction sanity check below fails fast with a clear message
  # rather than silently running an empty or malformed body.
  def extract_python_body
    yml = File.read(CI_YML_PATH)
    m = yml.match(/python3 - <<'EOF'\n(.*?)\n          EOF/m)
    raise "could not locate Python heredoc in ci.yml" unless m
    body = m[1].lines.map { |l| l.sub(/\A {10}/, "") }.join
    # Sanity-check the extracted body. If ci.yml's structure changes
    # (different indentation, different heredoc marker), fail loudly here
    # instead of running an empty or wrong script and getting confusing
    # downstream test failures.
    %w[unicodedata.category ALLOWED parse_allow is_suspicious].each do |token|
      raise "extracted Python body missing expected token #{token.inspect}; " \
            "ci.yml may have changed shape — update extract_python_body" \
        unless body.include?(token)
    end
    body
  end

  def run_python_in(dir)
    Dir.chdir(dir) do
      Open3.capture3("python3", "-c", extract_python_body)
    end
  end

  it "rejects a file with a bidi override character" do
    Dir.mktmpdir("blackoutd-ci-test-") do |dir|
      File.write(File.join(dir, "evil.c"), "int x;#{BIDI_OVERRIDE_RLO}\n")
      _out, err, status = run_python_in(dir)
      expect(status.success?).to eq(false), "stderr=#{err.inspect}"
      expect(err).to match(/Invisible Unicode|CVE-2021-42574/)
      expect(err).to include("evil.c")
    end
  end

  it "rejects a file containing a UTF-8 BOM" do
    Dir.mktmpdir("blackoutd-ci-test-") do |dir|
      File.write(File.join(dir, "bom.txt"), "#{UTF8_BOM}content\n")
      _out, err, status = run_python_in(dir)
      expect(status.success?).to eq(false)
      expect(err).to include("bom.txt")
    end
  end

  it "rejects UTF-16-encoded text" do
    Dir.mktmpdir("blackoutd-ci-test-") do |dir|
      utf16 = "hello world\n".encode(Encoding::UTF_16LE)
      File.binwrite(File.join(dir, "u16.txt"), "\xFF\xFE".b + utf16.b)
      _out, err, status = run_python_in(dir)
      expect(status.success?).to eq(false), "stderr=#{err.inspect}"
      expect(err).to include("u16.txt")
      expect(err).to match(/UTF-8/)
    end
  end

  it "rejects non-UTF-8 single-byte encoded text" do
    Dir.mktmpdir("blackoutd-ci-test-") do |dir|
      # Latin-1 byte 0xE9 is é but is invalid UTF-8 if not in a multi-byte
      # sequence.
      File.binwrite(File.join(dir, "latin1.txt"), "caf\xE9\n".b)
      _out, err, status = run_python_in(dir)
      expect(status.success?).to eq(false)
      expect(err).to include("latin1.txt")
    end
  end

  it "passes a clean repository tree" do
    Dir.mktmpdir("blackoutd-ci-test-") do |dir|
      File.write(File.join(dir, "ok.md"), "# Hello\n\nClean content.\n")
      File.write(File.join(dir, "ok.c"),  "int main(void) { return 0; }\n")
      _out, err, status = run_python_in(dir)
      expect(status.success?).to eq(true), "stderr=#{err.inspect}"
    end
  end

  describe "per-file opt-out via bidi-allow annotation" do
    it "passes a file with bidi-allow: U+200E and a real LRM character" do
      Dir.mktmpdir("blackoutd-ci-test-") do |dir|
        content = "// bidi-allow: U+200E\n" \
                  "package main\n" \
                  "var rtl = \"#{LRM}time\"\n"
        File.write(File.join(dir, "rtl.go"), content)
        _out, err, status = run_python_in(dir)
        expect(status.success?).to eq(true), "stderr=#{err.inspect}"
      end
    end

    it "still rejects codepoints not in the allow list" do
      Dir.mktmpdir("blackoutd-ci-test-") do |dir|
        content = "// bidi-allow: U+200E\n" \
                  "// hidden: #{BIDI_OVERRIDE_RLO} payload\n"
        File.write(File.join(dir, "evil.go"), content)
        _out, err, status = run_python_in(dir)
        expect(status.success?).to eq(false), "stderr=#{err.inspect}"
        expect(err).to include("evil.go")
      end
    end

    it "honors annotations placed deep in the file" do
      Dir.mktmpdir("blackoutd-ci-test-") do |dir|
        content = "# typed: true\n" \
                  "# frozen_string_literal: true\n" \
                  "\n" \
                  "# SPDX-FileCopyrightText: Copyright 2026 Test\n" \
                  "#\n" \
                  "# SPDX-License-Identifier: GPL-3.0-or-later\n" \
                  "\n" \
                  "# bidi-allow: U+200E\n" \
                  "x = \"#{LRM}content\"\n"
        File.write(File.join(dir, "deep.rb"), content)
        _out, err, status = run_python_in(dir)
        expect(status.success?).to eq(true), "stderr=#{err.inspect}"
      end
    end
  end
end
# REUSE-IgnoreEnd
