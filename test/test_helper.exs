ExUnit.start()

File.rm_rf!(Sentry.Sources.path_of_packaged_source_code())

ExUnit.after_suite(fn _ ->
  File.rm_rf!(Sentry.Sources.path_of_packaged_source_code())
end)
