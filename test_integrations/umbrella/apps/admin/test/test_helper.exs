Application.start(:nimble_options)
Application.start(:nimble_ownership)
{:ok, _} = Application.ensure_all_started(:finch)
Application.start(:sentry)

ExUnit.start()
