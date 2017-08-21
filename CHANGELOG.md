# Changelog

## master
* Breaking Changes
  * Remove use\_error\_logger configuration (#196)
* Bug Fixes
  * Fix README error (#197)
* Enhancements
  * Scrubbing of nested maps (#192)
  * Allow Hackney 1.9 and later (#199)

## 5.0.1 (2017-07-18)
* Bug Fixes
  * Fix logger and context usage (#185)

## 5.0.0 (2017-07-10)
* Backward incompatible changes
  * Allow specifying sync/async/none when getting result of sending event (#174)
* Enhancements
  * Modules (#182)
  * Config from system and DSN (#180)
  * App Frames (#177)
  * Sampling (#176)
  * Post event hook (#175)
  * Improve documentation around recompilation for source code context (#171)
  * Use better arity logic in stacktraces (#170)
  * Allow custom fingerprinting (#160)
* Bug Fixes
  * Fix README typo (#159)
  * Fix the backoff to really be exponential (#162)

## 4.0.3 (2017-05-17)

* Enhancements
  * Update and improve Travis build matrix (#155)
  * Specify behaviour for Sentry HTTP clients (#158)

## 4.0.2 (2017-04-26)

* Enhancements
  * Relax hackney requirements

## 4.0.1 (2017-04-25)

* Enhancements
  * Bump hackney to a version that fixes major bug (#153)

## 4.0.0 (2017-04-20)

See these [`3.0.0` to `4.0.0` upgrade instructions](https://gist.github.com/mitchellhenke/5248b3073f113309fa25550a0e4126d4) to update your existing app.

* Enhancements
  * Bump hackney to a version that isn't retired (#135)
  * Improve Logger reporting (#136)
  * Accept keyword lists in `Sentry.Context.add_breadcrumb/1` (#139)
  * Add elements to beginning of breadcrumbs list for performance (#141)
  * Close unread hackney responses properly (#149)
  * Improve `Sentry.Client` code style (#147)
  * Fix invalid specs in `Sentry` methods (#146)
  * Allow setting client at runtime (#150)
* Backward incompatible changes
  * Return `:ignored` instead of `{:ok, ""}` when event is not sent because environment\_name is not in included\_environments in `Sentry.send_event`, `Sentry.capture_exception`, or `Sentry.capture_message` (#146)
  * Return `:ignored` and log warning instead of returning `{:ok, "Sentry: unable to parse exception"}` when unable to parse exception in `Sentry.send_event`, `Sentry.capture_exception`, or `Sentry.capture_message` (#146)
  * Return `{:ok, Task}` instead of `Task` when an event is successfully sent with `Sentry.send_event`, `Sentry.capture_exception`, or `Sentry.capture_message` (#146)
  * Ignore non-existent route exceptions (#110)
  * Sending source code as context when reporting errors (#138)

## 3.0.0 (2017-03-02)
* Enhancements
  * Add dialyzer support (#128)
* Backward incompatible changes
  * Fix default configuration (#124)
  * Start and use separate Sentry hackney pool instead of default (#130)
  * Return `:error` instead of raising when encoding invalid JSON (#131)

## 2.2.0 (2017-02-15)

* Enhancements
  * Allow setting `hackney_opts`
  * Add `Sentry.capture_message/1`
  * Allow reading `:dsn` from System at runtime by configuring as `{:system, "ENV_VAR"}`

## 2.1.0 (2016-12-17)

* Enhancements
  * Allow filtering which exceptions are sent via `Sentry.EventFilter` behaviour
  * Add `Sentry.Context.set_http_context/1`

* Bug Fixes
  * Fix usage of deprecated modules
  * Fix README documentation
  * Fix timestamp parameter format

## 2.0.2 (2016-12-08)

* Bug Fixes
  * Fix regex checking of non-binary values

## 2.0.1 (2016-12-05)

* Bug Fixes
  * Fix compilation error when Plug is not available

## 2.0.0 (2016-11-28)

* Enhancements
  * Return a task when sending a Sentry event
  * Provide default scrubber for request body and headers (`Sentry.Plug.default_body_scrubber` and `Sentry.Plug.default_header_scrubber`)
  * Header scrubbing can now be configured with `:header_scrubber`

* Bug Fixes
  * Ensure `mix sentry.send_test_event` finishes sending event before ending Mix task

* Backward incompatible changes
  * `Sentry.capture_exception/1` now returns a `Task` instead of `{:ok, PID}`
  * Sentry.Plug `:scrubber` option has been removed in favor of the more descriptive `:body_scrubber`option, which defaults to newly added `Sentry.Plug.default_scrubber/1`
  * New option for Sentry.Plug `:header_scrubber` defaults to newly added `Sentry.Plug.default_header_scrubber/1`
  * Request bodies were not previously sent by default.  Because of above change, request bodies are now sent by default after being scrubbed by default scrubber.  To prevent sending any data, `:body_scrubber` should be set to `nil`
