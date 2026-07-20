# SPDX-FileCopyrightText: Copyright 2026 Todd Schulman
#
# SPDX-License-Identifier: GPL-3.0-or-later

require "open3"

# Behavioral tests for the blackoutd CLI's argument handling — the surface
# the manual checklist (spec/manual/TESTING.md) cannot cover cheaply:
# usage/validation/rejection paths, --version, --dry-run walkthroughs, and
# the preference write-back subcommands. Hardware- and daemon-affecting
# behavior (actual blackout, real sleep/wake recovery, launchctl lifecycle,
# live display cycling) stays in the manual checklist by design.
#
# The write-back subcommands (auto / verbosity / recovery) normally mutate
# the real "blackoutd" NSUserDefaults suite and SIGHUP the running daemon.
# The accept-path examples here set BLACKOUTD_DEFAULTS_SUITE to a throwaway
# suite (the src/main.m test seam): writes divert to that suite and the
# daemon is not signalled, so these tests never touch the user's real
# preferences or the running daemon.
#
# The macOS-only ObjC binary is built once in before(:all); the RSpec CI job
# runs on macos-latest but does not build, so the suite builds it itself.

BLACKOUTD_BIN = File.join(REPO_ROOT, "build", "blackoutd")

module CLISpecHelpers
  # Runs the built binary with args and optional env overrides.
  # Returns [stdout, stderr, Process::Status]. Output is forced to UTF-8:
  # Open3 returns ASCII-8BIT, and the usage text carries em-dashes that
  # would raise "invalid byte sequence" on a US-ASCII regex match.
  def blackoutd(*args, env: {})
    out, err, status = Open3.capture3(env, BLACKOUTD_BIN, *args)
    [out.force_encoding("UTF-8"), err.force_encoding("UTF-8"), status]
  end

  # Yields a unique throwaway NSUserDefaults suite name for accept-path
  # isolation, then best-effort removes it. Cleanup failure is ignored: the
  # suite name is unique per example and read by nothing.
  def with_isolated_suite
    suite = "blackoutd-test-#{Process.pid}-#{rand(1_000_000)}"
    yield suite
  ensure
    system("defaults", "delete", suite, out: File::NULL, err: File::NULL)
  end

  # Raw `defaults read` output for a key in the real suite (value line or the
  # "does not exist" message), used to assert the real suite is untouched.
  def real_default(key)
    out, = Open3.capture2e("defaults", "read", "blackoutd", key)
    out.force_encoding("UTF-8")
  end
end

RSpec.describe "blackoutd CLI" do
  include CLISpecHelpers

  before(:all) do
    skip "macOS-only ObjC binary" unless RUBY_PLATFORM.include?("darwin")
    out, err, status = Open3.capture3("make", "-C", REPO_ROOT)
    raise "make failed before CLI specs:\n#{out}#{err}" unless status.success?
    unless File.executable?(BLACKOUTD_BIN)
      raise "binary missing after build: #{BLACKOUTD_BIN}"
    end
  end

  describe "top-level dispatch" do
    it "prints usage to stderr and exits 1 with no arguments" do
      _out, err, status = blackoutd
      expect(status.exitstatus).to eq(1)
      expect(err).to include("Usage: blackoutd")
    end

    it "prints usage and exits 1 on an unknown command" do
      _out, err, status = blackoutd("frobnicate")
      expect(status.exitstatus).to eq(1)
      expect(err).to include("Usage: blackoutd")
    end

    it "lists every subcommand in the usage text" do
      _out, err, _status = blackoutd
      %w[on off status diagnose recover repro verbosity recovery auto
         daemon].each do |cmd|
        expect(err).to match(/^\s+#{Regexp.escape(cmd)}\b/)
      end
    end

    it "prints a semver version and build stamp on --version" do
      out, _err, status = blackoutd("--version")
      expect(status.exitstatus).to eq(0)
      expect(out).to match(/^blackoutd \d+\.\d+\.\d+ /)
      expect(out).to include("built:")
    end
  end

  describe "verbosity" do
    it "rejects a missing argument" do
      _out, err, status = blackoutd("verbosity")
      expect(status.exitstatus).to eq(1)
      expect(err).to include("Usage: blackoutd verbosity")
    end

    it "rejects a non-numeric level" do
      _out, err, status = blackoutd("verbosity", "high")
      expect(status.exitstatus).to eq(1)
      expect(err).to include("Usage: blackoutd verbosity")
    end

    it "rejects an out-of-range level" do
      _out, _err, status = blackoutd("verbosity", "3")
      expect(status.exitstatus).to eq(1)
    end

    it "persists a valid level to an isolated suite without signalling" do
      with_isolated_suite do |suite|
        out, _err, status =
          blackoutd("verbosity", "2",
                    env: { "BLACKOUTD_DEFAULTS_SUITE" => suite })
        expect(status.exitstatus).to eq(0)
        expect(out).to match(/verbosity: 2 .*isolated test suite/)
      end
    end
  end

  describe "recovery" do
    it "rejects a missing argument" do
      _out, err, status = blackoutd("recovery")
      expect(status.exitstatus).to eq(1)
      expect(err).to include("Usage: blackoutd recovery <none|displaysleep>")
    end

    it "rejects an unknown strategy" do
      _out, err, status = blackoutd("recovery", "bogus")
      expect(status.exitstatus).to eq(1)
      expect(err).to include("Usage: blackoutd recovery <none|displaysleep>")
    end

    it "accepts displaysleep against an isolated suite" do
      with_isolated_suite do |suite|
        out, _err, status =
          blackoutd("recovery", "displaysleep",
                    env: { "BLACKOUTD_DEFAULTS_SUITE" => suite })
        expect(status.exitstatus).to eq(0)
        expect(out).to match(/recovery: displaysleep .*isolated test suite/)
      end
    end

    it "accepts none against an isolated suite" do
      with_isolated_suite do |suite|
        out, _err, status =
          blackoutd("recovery", "none",
                    env: { "BLACKOUTD_DEFAULTS_SUITE" => suite })
        expect(status.exitstatus).to eq(0)
        expect(out).to match(/recovery: none .*isolated test suite/)
      end
    end

    it "leaves the real blackoutd suite untouched when isolated" do
      before_val = real_default("recoveryStrategy")
      with_isolated_suite do |suite|
        env = { "BLACKOUTD_DEFAULTS_SUITE" => suite }
        blackoutd("recovery", "none", env: env)
        blackoutd("recovery", "displaysleep", env: env)
      end
      expect(real_default("recoveryStrategy")).to eq(before_val)
    end
  end

  describe "auto" do
    it "rejects a missing argument" do
      _out, err, status = blackoutd("auto")
      expect(status.exitstatus).to eq(1)
      expect(err).to include("Usage: blackoutd auto [on|off]")
    end

    it "rejects an unknown value" do
      _out, err, status = blackoutd("auto", "maybe")
      expect(status.exitstatus).to eq(1)
      expect(err).to include("Usage: blackoutd auto [on|off]")
    end

    it "accepts off against an isolated suite" do
      with_isolated_suite do |suite|
        out, _err, status =
          blackoutd("auto", "off",
                    env: { "BLACKOUTD_DEFAULTS_SUITE" => suite })
        expect(status.exitstatus).to eq(0)
        expect(out).to match(/auto-blackout: disabled .*isolated test suite/)
      end
    end
  end

  describe "recover" do
    it "rejects an unknown method and lists the known ones" do
      _out, err, status = blackoutd("recover", "--method", "bogus")
      expect(status.exitstatus).to eq(1)
      expect(err).to include("displaysleep")
      expect(err).to include("extcycle")
      expect(err).to include("fbpower")
    end

    it "rejects an unknown option" do
      _out, err, status = blackoutd("recover", "--nope")
      expect(status.exitstatus).to eq(1)
      expect(err).to include("unknown recover option")
    end

    it "previews the displaysleep cycle under --dry-run" do
      out, _err, status =
        blackoutd("recover", "--method", "displaysleep", "--dry-run")
      expect(status.exitstatus).to eq(0)
      expect(out).to include("[dry-run]")
      expect(out).to include("pmset displaysleepnow")
      expect(out).to include("caffeinate")
    end

    it "previews the extcycle sequence under --dry-run" do
      out, _err, status =
        blackoutd("recover", "--method", "extcycle", "--dry-run")
      expect(status.exitstatus).to eq(0)
      expect(out).to match(/extcycle: disable external.*re-enable/)
    end

    it "previews the fbpower probe under --dry-run" do
      out, _err, status =
        blackoutd("recover", "--method", "fbpower", "--dry-run")
      expect(status.exitstatus).to eq(0)
      expect(out).to include("fbpower: open external-0")
    end
  end

  describe "repro argument validation" do
    it "rejects an unknown trigger before sleeping" do
      _out, err, status = blackoutd("repro", "--trigger", "bogus")
      expect(status.exitstatus).to eq(1)
      expect(err).to include("unknown trigger")
    end

    it "rejects a non-alphanumeric group" do
      _out, err, status = blackoutd("repro", "--group", "!!")
      expect(status.exitstatus).to eq(1)
      expect(err).to include("--group must be")
    end

    it "rejects an empty --wake" do
      _out, err, status = blackoutd("repro", "--wake", "")
      expect(status.exitstatus).to eq(1)
      expect(err).to include("non-negative integer")
    end

    it "rejects a non-numeric --settle" do
      _out, err, status = blackoutd("repro", "--settle", "abc")
      expect(status.exitstatus).to eq(1)
      expect(err).to include("non-negative integer")
    end

    it "rejects an unknown option" do
      _out, err, status = blackoutd("repro", "--frob")
      expect(status.exitstatus).to eq(1)
      expect(err).to include("unknown repro option")
    end
  end

  describe "repro --dry-run walkthrough" do
    # The step lines (sayCue prints "  [step] <text>") plus the sudo-prime
    # and schedule notices, in emission order.
    def dry_run_lines(*extra_args)
      out, err, status = blackoutd("repro", "--dry-run", *extra_args)
      expect(status.exitstatus).to eq(0)
      "#{out}#{err}".lines.map(&:chomp)
    end

    def index_of(lines, needle)
      lines.index { |l| l.include?(needle) }
    end

    it "orders the trigger BEFORE scheduling the wake (the W1 fix)" do
      lines = dry_run_lines("--wake", "15", "--trigger", "extcycle",
                            "--recover", "displaysleep")
      prime = index_of(lines, "priming sudo")
      trigger = index_of(lines, "triggering external cycle")
      schedule = index_of(lines, "scheduling wake")
      sleep_now = index_of(lines, "[step] sleeping now")
      awake = index_of(lines, "[step] awake")
      capture = index_of(lines, "capturing post wake")
      recover = index_of(lines, "[step] recovering")
      [prime, trigger, schedule, sleep_now, awake, capture,
       recover].each { |i| expect(i).not_to be_nil }
      # prime < trigger < schedule < sleepnow < awake < capture < recover
      expect(prime).to be < trigger
      expect(trigger).to be < schedule
      expect(schedule).to be < sleep_now
      expect(sleep_now).to be < awake
      expect(awake).to be < capture
      expect(capture).to be < recover
    end

    it "locks before scheduling the wake" do
      lines = dry_run_lines("--wake", "15", "--lock")
      lock = index_of(lines, "locking session")
      schedule = index_of(lines, "scheduling wake")
      expect(lock).not_to be_nil
      expect(schedule).not_to be_nil
      expect(lock).to be < schedule
    end

    it "speaks an awake cue between sleep and capture" do
      lines = dry_run_lines("--wake", "0")
      sleep_now = index_of(lines, "[step] sleeping now")
      awake = index_of(lines, "[step] awake")
      capture = index_of(lines, "capturing post wake")
      expect(awake).to be_between(sleep_now + 1, capture - 1)
    end

    it "skips sudo entirely for a manual wake (--wake 0)" do
      lines = dry_run_lines("--wake", "0")
      expect(lines.any? { |l| l.include?("priming sudo") }).to be false
      expect(lines.any? { |l| l.include?("scheduling wake") }).to be false
    end
  end

  describe "help lists the new subcommands and methods" do
    it "documents recovery, recover methods, and repro flags in usage" do
      _out, err, _status = blackoutd
      expect(err).to include("recovery <S>")
      expect(err).to include("extcycle")
      expect(err).to include("fbpower")
      expect(err).to include("--trigger")
      expect(err).to include("--lock")
    end
  end
end
