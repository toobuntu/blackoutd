# SPDX-FileCopyrightText: Copyright 2026 Todd Schulman
#
# SPDX-License-Identifier: GPL-3.0-or-later

require "fileutils"
require "open3"
require "tmpdir"

# Behavioral tests for scripts/lint-perms.sh — the single source of
# truth for the execute-bit policy on shipped scripts and git hooks.
# Both .githooks/pre-commit (--staged) and the lint-perms job in
# .github/workflows/ci.yml (--tracked) invoke this script.
#
# Tests cover the allowlist scope (scripts/*.sh, .githooks/pre-commit),
# anchored extension matching (no .sh.bak, no .sample), nested paths
# under scripts/, the --diff-filter=ACMRT scope (renames, type
# changes, symlinks), NUL-transport correctness on whitespace-bearing
# paths, and the pre-commit hook's trust guard for the script.

REPO_ROOT = File.expand_path("../../..", __FILE__)
LINT_PERMS_SRC = File.join(REPO_ROOT, "scripts", "lint-perms.sh")
HOOK_SRC = File.join(REPO_ROOT, ".githooks", "pre-commit")

module LintPermsSpecHelpers
  # Initializes a temp git repo with scripts/lint-perms.sh present and
  # staged 0755, then yields the working dir for the test to plant its
  # own files (symlinks, renames, etc.). Lower-level than with_git_repo.
  def with_bare_repo
    Dir.mktmpdir("blackoutd-perms-test-") do |dir|
      Dir.chdir(dir) do
        run!("git", "init", "--quiet", "--initial-branch=feature/test")
        run!("git", "config", "user.email", "test@example.invalid")
        run!("git", "config", "user.name",  "Test")
        FileUtils.mkdir_p("scripts")
        FileUtils.cp(LINT_PERMS_SRC, "scripts/lint-perms.sh")
        File.chmod(0o755, "scripts/lint-perms.sh")
        run!("git", "add", "scripts/lint-perms.sh")
        run!("git", "update-index", "--chmod=+x", "scripts/lint-perms.sh")
        yield dir
      end
    end
  end

  # Creates a temp git repo, copies lint-perms.sh into scripts/,
  # writes the planted files at the requested modes, stages them, and
  # yields the working dir.
  #
  # `files` maps relpath => [content, mode]. The script itself is
  # always present at scripts/lint-perms.sh (0755) and staged so
  # --tracked checks see it.
  def with_git_repo(files)
    with_bare_repo do |dir|
      files.each do |relpath, (content, mode)|
        FileUtils.mkdir_p(File.dirname(relpath))
        File.binwrite(relpath, content)
        File.chmod(mode, relpath)
        run!("git", "add", "--", relpath)
        # Force the index mode explicitly: `git add` honors the
        # filesystem mode (any +x → 100755, otherwise 100644), but
        # being explicit makes the test intent unambiguous.
        if (mode & 0o111).nonzero?
          run!("git", "update-index", "--chmod=+x", relpath)
        else
          run!("git", "update-index", "--chmod=-x", relpath)
        end
      end
      yield dir
    end
  end

  def run_lint_perms(*args, env: {})
    Open3.capture3(env, "./scripts/lint-perms.sh", *args)
  end

  def run!(*cmd)
    out, err, status = Open3.capture3(*cmd)
    raise "command failed: #{cmd.inspect}\nstdout: #{out}\nstderr: #{err}" unless status.success?
    [out, err]
  end
end

RSpec.describe "scripts/lint-perms.sh" do
  include LintPermsSpecHelpers

  describe "argument parsing" do
    it "rejects missing scope" do
      with_git_repo({}) do
        _out, err, status = run_lint_perms
        expect(status.success?).to eq(false)
        expect(status.exitstatus).to eq(2)
        expect(err).to match(/Usage:/)
      end
    end

    it "rejects an unknown scope" do
      with_git_repo({}) do
        _out, err, status = run_lint_perms("--bogus")
        expect(status.success?).to eq(false)
        expect(status.exitstatus).to eq(2)
        expect(err).to match(/Usage:/)
      end
    end

    it "prints help to stdout and exits 0 on --help" do
      with_git_repo({}) do
        out, _err, status = run_lint_perms("--help")
        expect(status.success?).to eq(true)
        expect(out).to match(/Usage:/)
        expect(out).to match(/LINT_PERMS_FORMAT/)
      end
    end
  end

  describe "--staged scope" do
    it "passes a scripts/*.sh staged at 0755" do
      with_git_repo("scripts/foo.sh" => ["#!/bin/sh\n", 0o755]) do
        _out, err, status = run_lint_perms("--staged")
        expect(status.success?).to eq(true), "stderr=#{err.inspect}"
      end
    end

    it "rejects a scripts/*.sh staged at 0644" do
      with_git_repo("scripts/foo.sh" => ["#!/bin/sh\n", 0o644]) do
        _out, err, status = run_lint_perms("--staged")
        expect(status.success?).to eq(false)
        expect(err).to include("scripts/foo.sh")
        expect(err).to include("100644")
        expect(err).to include("chmod 755")
      end
    end

    it "ignores scripts/*.sh.bak (anchored \\.sh$)" do
      with_git_repo("scripts/foo.sh.bak" => ["text\n", 0o644]) do
        _out, err, status = run_lint_perms("--staged")
        expect(status.success?).to eq(true), "stderr=#{err.inspect}"
      end
    end

    it "rejects .githooks/pre-commit at 0644" do
      with_git_repo(".githooks/pre-commit" => ["#!/bin/sh\n", 0o644]) do
        _out, err, status = run_lint_perms("--staged")
        expect(status.success?).to eq(false)
        expect(err).to include(".githooks/pre-commit")
      end
    end

    it "passes .githooks/pre-commit at 0755" do
      with_git_repo(".githooks/pre-commit" => ["#!/bin/sh\n", 0o755]) do
        _out, err, status = run_lint_perms("--staged")
        expect(status.success?).to eq(true), "stderr=#{err.inspect}"
      end
    end

    it "ignores .githooks/pre-commit.sample (allowlist excludes)" do
      with_git_repo(".githooks/pre-commit.sample" => ["#!/bin/sh\n", 0o644]) do
        _out, err, status = run_lint_perms("--staged")
        expect(status.success?).to eq(true), "stderr=#{err.inspect}"
      end
    end

    it "ignores .githooks/post-commit (not in allowlist)" do
      # New hooks must be added to the allowlist deliberately. This
      # test pins the current contract; remove or update it when
      # post-commit is added to PERMS_PATTERN.
      with_git_repo(".githooks/post-commit" => ["#!/bin/sh\n", 0o644]) do
        _out, err, status = run_lint_perms("--staged")
        expect(status.success?).to eq(true), "stderr=#{err.inspect}"
      end
    end

    it "rejects a nested scripts/sub/foo.sh at 0644" do
      with_git_repo("scripts/sub/foo.sh" => ["#!/bin/sh\n", 0o644]) do
        _out, err, status = run_lint_perms("--staged")
        expect(status.success?).to eq(false)
        expect(err).to include("scripts/sub/foo.sh")
      end
    end

    it "passes a nested scripts/sub/foo.sh at 0755" do
      with_git_repo("scripts/sub/foo.sh" => ["#!/bin/sh\n", 0o755]) do
        _out, err, status = run_lint_perms("--staged")
        expect(status.success?).to eq(true), "stderr=#{err.inspect}"
      end
    end

    it "handles paths with whitespace (NUL transport)" do
      with_git_repo("scripts/with space.sh" => ["#!/bin/sh\n", 0o644]) do
        _out, err, status = run_lint_perms("--staged")
        expect(status.success?).to eq(false), "stderr=#{err.inspect}"
        expect(err).to include("scripts/with space.sh")
        expect(err).to include("100644")
      end
    end

    it "passes when no shipped scripts are staged" do
      with_git_repo("README.md" => ["text\n", 0o644]) do
        _out, err, status = run_lint_perms("--staged")
        expect(status.success?).to eq(true), "stderr=#{err.inspect}"
      end
    end

    it "reports all offenders, not just the first" do
      files = {
        "scripts/foo.sh" => ["#!/bin/sh\n", 0o644],
        "scripts/bar.sh" => ["#!/bin/sh\n", 0o644],
      }
      with_git_repo(files) do
        _out, err, status = run_lint_perms("--staged")
        expect(status.success?).to eq(false)
        expect(err).to include("scripts/foo.sh")
        expect(err).to include("scripts/bar.sh")
      end
    end
  end

  describe "diff-filter scope (ACMRT): renames, type changes, symlinks" do
    it "skips a symlink whose name matches scripts/*.sh" do
      # A symlink is stored as mode 120000; the exec bit applies to the
      # target, not the link. The check must not flag it.
      with_bare_repo do
        File.symlink("/usr/bin/true", "scripts/link.sh")
        run!("git", "add", "scripts/link.sh")
        _out, err, status = run_lint_perms("--staged")
        expect(status.success?).to eq(true), "stderr=#{err.inspect}"
      end
    end

    it "catches a bad mode introduced by a rename (R is in scope)" do
      # Without R in --diff-filter, a pure rename to a new path slips
      # the check. Commit a good script, rename it, drop its exec bit,
      # and confirm the destination path is still verified.
      with_bare_repo do
        File.binwrite("scripts/foo.sh", "#!/bin/sh\n")
        File.chmod(0o755, "scripts/foo.sh")
        run!("git", "add", "scripts/foo.sh")
        run!("git", "update-index", "--chmod=+x", "scripts/foo.sh")
        run!("git", "commit", "--quiet", "--message", "init")
        run!("git", "mv", "scripts/foo.sh", "scripts/bar.sh")
        run!("git", "update-index", "--chmod=-x", "scripts/bar.sh")
        _out, err, status = run_lint_perms("--staged")
        expect(status.success?).to eq(false), "stderr=#{err.inspect}"
        expect(err).to include("scripts/bar.sh")
        expect(err).to include("100644")
      end
    end
  end

  describe "--tracked scope" do
    it "catches a mode regression on a committed file" do
      with_git_repo("scripts/foo.sh" => ["#!/bin/sh\n", 0o755]) do
        run!("git", "commit", "--quiet", "--message", "init")
        # No new staged changes; regress the tracked mode directly.
        run!("git", "update-index", "--chmod=-x", "scripts/foo.sh")
        _out, err, status = run_lint_perms("--tracked")
        expect(status.success?).to eq(false), "stderr=#{err.inspect}"
        expect(err).to include("scripts/foo.sh")
        expect(err).to include("100644")
      end
    end

    it "passes when all tracked shipped scripts are 0755" do
      with_git_repo("scripts/foo.sh" => ["#!/bin/sh\n", 0o755]) do
        run!("git", "commit", "--quiet", "--message", "init")
        _out, err, status = run_lint_perms("--tracked")
        expect(status.success?).to eq(true), "stderr=#{err.inspect}"
      end
    end
  end

  describe "LINT_PERMS_FORMAT=ci" do
    it "emits GitHub Annotations on stdout (not stderr)" do
      with_git_repo("scripts/foo.sh" => ["#!/bin/sh\n", 0o644]) do
        out, err, status = run_lint_perms("--staged",
                                          env: { "LINT_PERMS_FORMAT" => "ci" })
        expect(status.success?).to eq(false)
        expect(out).to include("::error file=scripts/foo.sh::missing execute bit")
        expect(out).to include("chmod 755")
        expect(err).to be_empty
      end
    end
  end
end

# Verifies the trust guard in .githooks/pre-commit: when
# scripts/lint-perms.sh is absent or not executable, the hook must
# fail early with a clear, actionable message rather than a cryptic
# "command not found" / "Permission denied".
RSpec.describe "pre-commit hook: lint-perms.sh trust guard" do
  include LintPermsSpecHelpers

  def setup_repo_with_hook_no_script
    Dir.mktmpdir("blackoutd-guard-test-") do |dir|
      Dir.chdir(dir) do
        run!("git", "init", "--quiet", "--initial-branch=feature/test")
        run!("git", "config", "user.email", "test@example.invalid")
        run!("git", "config", "user.name",  "Test")
        FileUtils.mkdir_p(".githooks")
        FileUtils.cp(HOOK_SRC, ".githooks/pre-commit")
        File.chmod(0o755, ".githooks/pre-commit")
        run!("git", "config", "core.hooksPath", ".githooks")
        File.write("dummy.txt", "content\n")
        run!("git", "add", "dummy.txt")
        yield dir
      end
    end
  end

  it "errors out cleanly when scripts/lint-perms.sh is missing" do
    setup_repo_with_hook_no_script do
      _out, err, status = Open3.capture3(
        { "GIT_DIR" => ".git", "GIT_INDEX_FILE" => ".git/index" },
        "./.githooks/pre-commit"
      )
      expect(status.success?).to eq(false)
      expect(err).to include("scripts/lint-perms.sh missing or not executable")
      expect(err).to include("chmod 755")
    end
  end

  it "errors out cleanly when scripts/lint-perms.sh is present but not executable" do
    setup_repo_with_hook_no_script do
      FileUtils.mkdir_p("scripts")
      FileUtils.cp(LINT_PERMS_SRC, "scripts/lint-perms.sh")
      File.chmod(0o644, "scripts/lint-perms.sh")
      _out, err, status = Open3.capture3(
        { "GIT_DIR" => ".git", "GIT_INDEX_FILE" => ".git/index" },
        "./.githooks/pre-commit"
      )
      expect(status.success?).to eq(false)
      expect(err).to include("scripts/lint-perms.sh missing or not executable")
    end
  end
end
