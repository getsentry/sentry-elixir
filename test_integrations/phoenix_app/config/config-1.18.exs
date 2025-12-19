import Config

# See: https://github.com/getsentry/sentry-elixir/issues/951
config :sentry,
  enable_source_code_context: true,
  root_source_code_paths: [File.cwd!()],
  source_code_exclude_patterns: ["/_build/", "/deps/", "/priv/", "/test/"]
