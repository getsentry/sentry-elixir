import Config

# See: https://github.com/getsentry/sentry-elixir/issues/951
config :sentry,
  enable_source_code_context: true,
  root_source_code_paths: [File.cwd!()],
  source_code_exclude_patterns: [~r/_build/E, ~r/deps/E, ~r/priv/E, ~r/test/E]
