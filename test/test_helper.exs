ExUnit.start(assert_receive_timeout: 500)

File.rm_rf!(Sentry.Sources.path_of_packaged_source_code())

ExUnit.after_suite(fn _ ->
  File.rm_rf!(Sentry.Sources.path_of_packaged_source_code())
end)

{:ok, _} = Plug.Cowboy.http(Sentry.ExamplePlugApplication, [], port: 8003)
