# SPDX-FileCopyrightText: Copyright 2026 Todd Schulman
#
# SPDX-License-Identifier: GPL-3.0-or-later

# Repo root shared by the integration specs. Defined once here — each
# spec previously defined its own copy, tripping Ruby's
# already-initialized-constant warning under config.warnings.
REPO_ROOT = File.expand_path("..", __dir__)

RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.shared_context_metadata_behavior = :apply_to_host_groups
  config.disable_monkey_patching!
  config.warnings = true
  config.default_formatter = "doc" if config.files_to_run.one?
  config.order = :random
  Kernel.srand config.seed
end
