# SPDX-FileCopyrightText: Copyright 2026 Todd Schulman
#
# SPDX-License-Identifier: GPL-3.0-or-later

require "fileutils"
require "open3"
require "tmpdir"

# Regression test for the REUSE-failure path in .githooks/pre-commit.
# A `set -e` bug let the bare `reuse lint-file` re-run terminate the
# hook before the annotate hint and the explicit `exit 1` could run,
# so a developer staging a non-compliant file saw a silent non-zero
# exit. The fix appends `|| true` to that re-run; this test pins it.
#
# A stubbed `reuse` (always non-compliant) drives the failure path
# deterministically, independent of any real reuse install — the CI
# spec runner has none.
RSpec.describe "pre-commit hook: REUSE non-compliance surfaces the annotate hint" do
  let(:hook_src) { File.expand_path("../../.githooks/pre-commit", __dir__) }
  let(:lint_perms_src) { File.expand_path("../../scripts/lint-perms.sh", __dir__) }

  def sh!(*cmd)
    out, err, status = Open3.capture3(*cmd)
    raise "command failed: #{cmd.inspect}\nstdout: #{out}\nstderr: #{err}" unless status.success?
  end

  it "prints the annotate hint to stderr and exits non-zero" do
    Dir.mktmpdir("blackoutd-reuse-test-") do |dir|
      Dir.chdir(dir) do
        sh!("git", "init", "--quiet", "--initial-branch=feature/test")
        sh!("git", "config", "user.email", "test@example.invalid")
        sh!("git", "config", "user.name", "Test")
        FileUtils.mkdir_p(".githooks")
        FileUtils.cp(hook_src, ".githooks/pre-commit")
        File.chmod(0o755, ".githooks/pre-commit")
        sh!("git", "config", "core.hooksPath", ".githooks")
        FileUtils.mkdir_p("scripts")
        FileUtils.cp(lint_perms_src, "scripts/lint-perms.sh")
        File.chmod(0o755, "scripts/lint-perms.sh")
        sh!("git", "add", "scripts/lint-perms.sh")
        sh!("git", "update-index", "--chmod=+x", "scripts/lint-perms.sh")
        File.write("uncovered.txt", "no SPDX header here\n")
        sh!("git", "add", "uncovered.txt")
        # Stub reuse: always non-compliant, so the failure path runs
        # regardless of a real reuse install.
        bindir = File.join(dir, "fakebin")
        FileUtils.mkdir_p(bindir)
        File.write(File.join(bindir, "reuse"), "#!/bin/sh\nexit 1\n")
        File.chmod(0o755, File.join(bindir, "reuse"))
        _out, err, status = Open3.capture3(
          { "GIT_DIR" => ".git", "GIT_INDEX_FILE" => ".git/index",
            "PATH" => "#{bindir}:#{ENV['PATH']}" },
          "./.githooks/pre-commit"
        )
        expect(status.success?).to eq(false), "stderr=#{err.inspect}"
        expect(err).to include("scripts/annotate.sh")
      end
    end
  end
end
