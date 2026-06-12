# SPDX-FileCopyrightText: Copyright 2026 Todd Schulman
#
# SPDX-License-Identifier: GPL-3.0-or-later

require "fileutils"
require "open3"
require "tmpdir"

# Behavioral tests for the .githooks/pre-push signed-push gate.
#
# The hook is driven directly, the way git invokes it: argv carries the remote
# name and URL, stdin carries "<local_ref> <local_oid> <remote_ref>
# <remote_oid>" lines. Each example builds a throwaway repository with
# hermetic SSH signing (a generated key plus gpg.ssh.allowedSignersFile, so
# `%G?` verifies to G without touching the developer's keys or global config —
# HOME and GIT_CONFIG_GLOBAL point into the tmpdir). No network, no real
# remote.

PREPUSH_HOOK = File.join(REPO_ROOT, ".githooks", "pre-push")
ZERO_OID = "0" * 40

module PrePushSpecHelpers

  # Creates a temp repo (optionally with hermetic SSH signing configured) and
  # yields [dir, env]. The env isolates git from the developer's real global
  # and system config so enforcement auto-detection is deterministic.
  def with_repo(signing: true)
    Dir.mktmpdir("blackoutd-prepush-") do |dir|
      env = {
        "HOME" => dir,
        "GIT_CONFIG_GLOBAL" => File.join(dir, "gitconfig-global"),
        "GIT_CONFIG_SYSTEM" => "/dev/null",
      }
      File.write(env["GIT_CONFIG_GLOBAL"], "")
      run!(env, "git", "init", "--quiet", "--initial-branch=main", dir)
      g(env, dir, "config", "user.email", "test@example.invalid")
      g(env, dir, "config", "user.name", "Test")
      g(env, dir, "remote", "add", "origin", "file:///dev/null")
      if signing
        key = File.join(dir, "signing-key")
        run!(env, "ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", key)
        type_and_blob = File.read("#{key}.pub").split[0, 2].join(" ")
        allowed = File.join(dir, "allowed-signers")
        File.write(allowed, "test@example.invalid #{type_and_blob}\n")
        g(env, dir, "config", "gpg.format", "ssh")
        g(env, dir, "config", "user.signingkey", "#{key}.pub")
        g(env, dir, "config", "gpg.ssh.allowedSignersFile", allowed)
        # Sign per-commit via --gpg-sign; auto-detection keys on signingkey.
        g(env, dir, "config", "commit.gpgsign", "false")
      end
      yield dir, env
    end
  end

  def run!(env, *cmd)
    out, err, status = Open3.capture3(env, *cmd)
    raise "#{cmd.join(" ")} failed:\n#{err}#{out}" unless status.success?
    out
  end

  def g(env, dir, *args)
    run!(env, "git", "-C", dir, *args)
  end

  def commit(env, dir, msg, signed:)
    flag = signed ? "--gpg-sign" : "--no-gpg-sign"
    g(env, dir, "commit", "--quiet", "--allow-empty", flag, "--message", msg)
    g(env, dir, "rev-parse", "HEAD").strip
  end

  def short(env, dir, oid)
    g(env, dir, "rev-parse", "--short", oid).strip
  end

  def push_line(local_oid, remote_oid, ref: "refs/heads/main")
    "#{ref} #{local_oid} #{ref} #{remote_oid}\n"
  end

  def run_hook(env, dir, stdin_lines, remote: "origin")
    Open3.capture3(env, PREPUSH_HOOK, remote, "file:///dev/null",
                   stdin_data: stdin_lines, chdir: dir)
  end
end

RSpec.describe ".githooks/pre-push signed-push gate" do
  include PrePushSpecHelpers

  describe "enforcement (signing configured)" do
    it "passes a fully signed ref update" do
      with_repo do |dir, env|
        base = commit(env, dir, "base", signed: true)
        tip = commit(env, dir, "tip", signed: true)
        _, err, status = run_hook(env, dir, push_line(tip, base))
        expect(status.exitstatus).to eq(0), err
        expect(err).to be_empty
      end
    end

    it "rejects an unsigned tip and pins the re-sign hint to it" do
      with_repo do |dir, env|
        base = commit(env, dir, "base", signed: true)
        tip = commit(env, dir, "tip", signed: false)
        _, err, status = run_hook(env, dir, push_line(tip, base))
        expect(status.exitstatus).to eq(1)
        expect(err).to include("1 unsigned commit(s)")
        expect(err).to include(short(env, dir, tip))
        expect(err).to include("#{tip}^")
      end
    end

    it "rejects an unsigned commit buried under a signed tip" do
      with_repo do |dir, env|
        base = commit(env, dir, "base", signed: true)
        buried = commit(env, dir, "buried", signed: false)
        tip = commit(env, dir, "tip", signed: true)
        _, err, status = run_hook(env, dir, push_line(tip, base))
        expect(status.exitstatus).to eq(1)
        expect(err).to include(short(env, dir, buried))
        expect(err).to include("#{buried}^")
      end
    end

    it "skips ref deletions" do
      with_repo do |dir, env|
        tip = commit(env, dir, "tip", signed: true)
        _, err, status = run_hook(env, dir, push_line(ZERO_OID, tip))
        expect(status.exitstatus).to eq(0), err
      end
    end

    it "skips refs that do not peel to a commit" do
      with_repo do |dir, env|
        commit(env, dir, "base", signed: true)
        blob, = Open3.capture2(env, "git", "-C", dir, "hash-object", "-w",
                               "--stdin", stdin_data: "payload\n")
        g(env, dir, "tag", "--annotate", "--message", "m", "blobtag",
          blob.strip)
        tag_oid = g(env, dir, "rev-parse", "refs/tags/blobtag").strip
        line = push_line(tag_oid, ZERO_OID, ref: "refs/tags/blobtag")
        _, err, status = run_hook(env, dir, line)
        expect(status.exitstatus).to eq(0), err
      end
    end

    it "suggests --root when the earliest unsigned commit has no parent" do
      with_repo do |dir, env|
        root = commit(env, dir, "root", signed: false)
        _, err, status = run_hook(env, dir, push_line(root, ZERO_OID))
        expect(status.exitstatus).to eq(1)
        expect(err).to include("git rebase --root --exec")
        expect(err).not_to include("#{root}^")
      end
    end

    it "validates only the commits a new branch adds" do
      with_repo do |dir, env|
        base = commit(env, dir, "base", signed: true)
        g(env, dir, "update-ref", "refs/remotes/origin/main", base)
        g(env, dir, "switch", "--quiet", "--create", "feature")
        added = commit(env, dir, "feature work", signed: false)
        line = push_line(added, ZERO_OID, ref: "refs/heads/feature")
        _, err, status = run_hook(env, dir, line)
        expect(status.exitstatus).to eq(1)
        expect(err).to include("1 unsigned commit(s)")
        expect(err).to include(short(env, dir, added))
      end
    end

    it "passes a new branch whose added commits are signed" do
      with_repo do |dir, env|
        base = commit(env, dir, "base", signed: false)
        g(env, dir, "update-ref", "refs/remotes/origin/main", base)
        g(env, dir, "switch", "--quiet", "--create", "feature")
        added = commit(env, dir, "feature work", signed: true)
        line = push_line(added, ZERO_OID, ref: "refs/heads/feature")
        _, err, status = run_hook(env, dir, line)
        expect(status.exitstatus).to eq(0), err
      end
    end

    it "fails closed when the remote tip is not present locally" do
      with_repo do |dir, env|
        tip = commit(env, dir, "tip", signed: true)
        _, err, status = run_hook(env, dir, push_line(tip, "deadbeef" * 5))
        expect(status.exitstatus).to eq(1)
        expect(err).to include("git fetch origin")
      end
    end
  end

  describe "contributor mode (signing not configured)" do
    it "warns about unsigned commits but allows the push" do
      with_repo(signing: false) do |dir, env|
        tip = commit(env, dir, "tip", signed: false)
        _, err, status = run_hook(env, dir, push_line(tip, ZERO_OID))
        expect(status.exitstatus).to eq(0), err
        expect(err).to include("pre-push warning")
        expect(err).to include("push allowed")
      end
    end

    it "hooks.requireSignedPush=true enforces anyway" do
      with_repo(signing: false) do |dir, env|
        g(env, dir, "config", "hooks.requireSignedPush", "true")
        tip = commit(env, dir, "tip", signed: false)
        _, err, status = run_hook(env, dir, push_line(tip, ZERO_OID))
        expect(status.exitstatus).to eq(1)
        expect(err).to include("Push rejected")
      end
    end
  end

  describe "explicit opt-out" do
    it "hooks.requireSignedPush=false warns without blocking" do
      with_repo do |dir, env|
        g(env, dir, "config", "hooks.requireSignedPush", "false")
        base = commit(env, dir, "base", signed: true)
        tip = commit(env, dir, "tip", signed: false)
        _, err, status = run_hook(env, dir, push_line(tip, base))
        expect(status.exitstatus).to eq(0), err
        expect(err).to include("pre-push warning")
      end
    end
  end
end
