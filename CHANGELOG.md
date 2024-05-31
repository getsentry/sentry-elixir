# Changelog

## 10.6.1

### Various fixes & improvements

- Only fetch LiveView socket info if root (#734) by @whatyouhide

## 10.6.0

### Various fixes & improvements

- Add overload protection to `:logger` handler (#727).
- Expose DSN via new `Sentry.get_dsn/0` (#731).
- Fix a bug with nameless Quantum cron jobs support in the Quantum integration.

## 10.5.0

### Various fixes & improvements

- Improve resilience of looking at Retry-After (ab7fbb96) by @whatyouhide
- Fix compilation error (cf93d226) by @whatyouhide
- Honor Retry-After responses from Sentry (5bad4b56) by @whatyouhide
- Improve "GenServer terminating" reports (#723) by @whatyouhide
- Don't report empty stacktraces (bed583f5) by @whatyouhide
- Add LiveView hook (#722) by @whatyouhide
- FIx monitor slug in Oban + Quantum integrations (#721) by @whatyouhide

## 10.4.0

### Various fixes & improvements

- Add rate-limiting to `Sentry.LoggerHandler`.
- Improve reporting of process crashes in `Sentry.LoggerHandler`.
- Fix loading configuration in `mix sentry.send_test_event`.
- Fix JSON libraries that raise errors when encoding.
- Allow `Sentry.LoggerBackend` and `Sentry.LoggerHandler` to use Sentry metadata.
- Validate configuration passed to `Sentry.LoggerHandler`.

## 10.3.0

### Various fixes & improvements

- Fix compilation warning (83a727a3) by @whatyouhide
- Move some integrations-related modules around (8eeca145) by @whatyouhide
- Add integrated support for capturing Oban errors (#705) by @whatyouhide

## 10.2.1

### Various fixes & improvements

- Fix automatic start integrations (#704) by @vshev4enko
- Fix wrong CLI argument in CI (#701) by @vshev4enko
- Update changelog (d6da0fbe) by @whatyouhide

## 10.2.0

### New features

- Add support for [Sentry Cron](https://docs.sentry.io/product/crons/) monitoring, with built-in support for [Oban](https://github.com/sorentwo/oban) and [Quantum](https://github.com/quantum-elixir/quantum-core).
- Add `Sentry.capture_check_in/1`, which can be used to manually check-in crons.
- Add `--output` flag for the `mix sentry.package_source_code` task. This can be useful for read-only build environments.
- Introduce testing helpers in `Sentry.Test`.
- Add the `:url_scrubber` option to `Sentry.PlugContext`.

### Various fixes & improvements

- Improve error message on unavailable config.

## 10.1.0

### Various fixes & improvements

- Add `Sentry.Interfaces.Thread` to fix stacktraces in messages.
- Add the `--type` and `--no-stacktrace` flags to `mix sentry.send_test_message`.
- Add support for interpolating messages (with `%s`) placeholders. See `Sentry.capture_message/2`.
- Add support for attachments; see `Sentry.Attachment` and `Sentry.Context.add_attachment/1`.

## 10.0.3

### Various fixes & improvements

- No "app.config" in "mix sentry.package_source_code" (#661) by @whatyouhide
- Add upgrade guide links to the changelog (#659) by @axelson

## 10.0.2

### Various fixes & improvements

- Fix infinite logging loop (#657) by @whatyouhide
- Remove reference to "before_send_event" in README (f1650502) by @whatyouhide
- Don't report events if DSN is not configured (#655) by @whatyouhide

## 10.0.1

### Various fixes & improvements

- Fix reading of config in "mix sentry.package_source_code" (#653)
- Don't ship Dialyzer PLTs with releases (#654)

## 10.0.0

[9.x -> 10.0 Upgrade Guide](https://hexdocs.pm/sentry/upgrade-10-x.html)

- `:report_deps` now reports all loaded applications at the time the `:sentry` application starts. This is not a compile-time configuration option anymore.
- Add the `mix sentry.package_source_code` Mix task. See the upgrade guide for more information.
- Add `~r"/test/"` to the default source code exclude patterns (see the `:source_code_exclude_patterns` option).
- `:environment_name` now defaults to `production` (if it wasn't configured explicitly and if the `SENTRY_ENVIRONMENT` environment variable is not set).
- Hard-deprecate `:included_environments`. To control whether to send events to Sentry, use the `:dsn` configuration option instead. `:included_environments` now emits a warning if used, but will still work until v11.0.0 of this library.
- Hard-deprecate `:before_send_event` in favor of the new `:before_send`. This brings this SDK in line with all other Sentry SDKs.

## 9.1.0

### Various fixes & improvements

- Attempt to scrub all `Plug.Conn`s in `Sentry.PlugCapture` (#619) by @whatyouhide
- Fix typespec for the `Sentry.Context.t/0` type (#618) by @whatyouhide
- Apply `:sample_rate` *after* event callbacks, rather than *before* (ab5c7485) by @whatyouhide

## 9.0.0

[8.x -> 9.0 Upgrade Guide](https://hexdocs.pm/sentry/upgrade-9-x.html)

### Breaking changes

- Removed `Sentry.Sources`
- Removed `Sentry.Client`, as it's an internal module
- Removed the `Sentry.Event.sentry_exception/0` type
- Removed `Sentry.Event.add_metadata/1`
- Removed `Sentry.Event.culprit_from_stacktrace/1`
- Removed `Sentry.Event.do_put_source_context/3`
- Removed the `:async` value for the `:result` option in `Sentry.send_event/2` (and friends)
- Removed `Sentry.CrashError` — now, crash reports (detected through `Sentry.LoggerBackend`) that do not contain exceptions are reported as *messages* in Sentry
- Changed the shape of the `Sentry.Event` struct - check out the new fields (and typespec for `Sentry.Event.t/0`)

### Various fixes & improvements

- Add `Sentry.LoggerHandler`, which is a `:logger` handler rather than a `Logger` backend
- Make the `Sentry.HTTPClient.child_spec/0` callback optional
- Add `:all` as a possible value of the `:metadata` configuration option for `Sentry.LoggerBackend`
- Add `:all` as a possible value for the `:included_environment` configuration option
- Add `Sentry.Interfaces` with all the child modules, which are useful if you're working directly with the Sentry API
- Fix an issue with JSON-encoding non-encodable terms (such as PIDs, which are pretty common)

### Deprecations

- Soft-deprecate `Sentry.EventFilter` in favour of `:before_send_event` callbacks.

### Various fixes & improvements

- Remove manually-entered entries from the CHANGELOG (48cf37d9) by @whatyouhide
- Don't cover test/support in tests (8cfe14b1) by @whatyouhide
- Make two more funs private in Sentry.Event (340ba143) by @whatyouhide
- Add excoveralls for code coverage (58d94cf2) by @whatyouhide
- Clean up Sentry.Config (f996c7d3) by @whatyouhide
- Revert default :included_environments to [:prod] (d33bf19d) by @whatyouhide
- Send async events right away without queueing (#612) by @whatyouhide
- Make Sentry.Interfaces.Request a struct (#611) by @whatyouhide
- Improve some tests (59e8ebb0) by @whatyouhide
- Add Sentry logo to the docs (6d27eacf) by @whatyouhide
- Polish docs for "mix sentry.send_test_event" (903aeb93) by @whatyouhide
- Update changelog and error messages (f6f577f4) by @whatyouhide
- Soft-deprecate Sentry.EventFilter (#608) by @whatyouhide
- Improve Sentry.Event struct definition (#609) by @whatyouhide
- Clean up docs and tests for "mix sentry.send_test_event" (#610) by @whatyouhide
- Add Sentry.LoggerHandler (#607) by @whatyouhide
- Remove Sentry.CrashError and improve EXIT reporting (#606) by @whatyouhide
- Support :all in Sentry.LoggerBackend's :metadata (#605) by @whatyouhide
- Optimize JSON sanitization step (b96d6cfd) by @whatyouhide
- Accept all environments by default (#604) by @whatyouhide
- Add example about alternative HTTP client to docs (38e80edf) by @whatyouhide
- Make Sentry.HTTPClient.child_spec/0 optional (#603) by @whatyouhide
- Clean up a bunch of little non-important things (18e83ae9) by @whatyouhide
- Simplify test GenServer (30a9828e) by @whatyouhide

## 8.1.0

### Various fixes & improvements

- Bump min craft version to 1.4.2 (795bfd12) by @sl0thentr0py
- Add github target to craft (ef563cc5) by @sl0thentr0py
- Bump min craft version (56516be2) by @sl0thentr0py
- Improve deprecation of Sentry.Config.root_source_code_path/0 (#558) by @whatyouhide
- Wrap HTTP requests in try/catch (#515) by @ruslandoga
- Remove extra config files (#556) by @yordis
- Remove use of deprecated Mix.Config (#555) by @whatyouhide
- Add release/** branches to ci for craft (dfaffb9f) by @sl0thentr0py
- Fix typo in moduledoc (#534) by @louisvisser
- Check :hackney application when starting (#554) by @whatyouhide
- feat(event): filter more exceptions by default (#550) by @gpouilloux
- Fix example configuration for Sentry.Sources (#543) by @scudelletti
- Use module attribute for dictionary key consistently (#537) by @tmecklem
- Fix send_event/2 typespec (#545) by @ruslandoga
- Update badges in the README (#548) by @ruslandoga
- Update ex_docs to 0.29+ (#549) by @ruslandoga
- Fix Elixir 1.15 warnings (#553) by @dustinfarris
- Add :remote_address_reader PlugContext option (#519) by @michallepicki
- Traverse full domain list when checking for excluded domains (#508) by @martosaur
- Add craft with target hex (#532) by @sl0thentr0py
- Add Sentry to LICENSE (#530) by @sl0thentr0py
- Update ci setup-beam action name (#531) by @sl0thentr0py
- allow logging from tasks (#517) by @ruslandoga
- Improve DSN parsing and Endpoint building (#507) by @AtjonTV

_Plus 14 more_

## 8.0.6 (2021-09-28)

* Bug Fixes
  * Remove function that disables non-group leader logging (#467)
  * Handle :unsampled events in `Sentry.send_test_event` (#474)
  * Fix dialyzer reporting unmatched\_return for Sentry.PlugCapture (#475)
  * Use correct `Plug.Parsers` exception module (#482)

## 8.0.5 (2021-02-14)

* Enhancements
  * Support lists in scrubbing (#442)
  * Send Sentry reports on uncaught throws/exits (#447)

* Bug Fixes
  * Deprecate `Sentry.Config.in_app_module_whitelist` in favor of `Sentry.Config.in_app_module_allow_list` (#450)
  * Update outdated `Sentry.Plug` documentation (#452)
  * Update `Sentry.HTTPClient` documentation (#456)

## 8.0.4 (2020-11-16)

* Bug Fixes
  * Do not read DSN config at compile time (#441)

## 8.0.3 (2020-11-11)

* Enhancements
  * Update package & docs configuration (#432)
  * Add Plug.Status filter example (#433)
  * Support multiple source code root paths in Sentry.Sources (#437)

* Bug Fixes
  * Fix dialyzer reporting unmatched_return for Sentry.PlugCapture (#436)
  * Align Sentry event levels with Elixir logging levels (#439)

## 8.0.2 (2020-09-06)

* Enhancements
  * Log error when JSON is unencodable (#429)
  * Set logger event level to logger message level (#430)
  * Limit breadcrumbs on add_breadcrumb (#431)

## 8.0.1 (2020-08-08)

* Enhancements
  * Add plug parsing errors to list of default excluded params (#414)
  * Make Sentry.PlugContext.scrub\_map public (#417)
  * Allow users to configure maximum number of breadcrumbs (#418)

## 8.0.0 (2020-07-13)
[7.x -> 8.0 Upgrade Guide](https://gist.github.com/mitchellhenke/dce120a5515565076b13962ee0be749b)

* Bug Fixes
  * Fix documentation for `Sentry.PlugContext` (#410)

## 8.0.0-rc.2 (2020-07-01)
* Bug Fixes
  * Fix trying to transform erlang error coming from PlugCapture (#406)

## 8.0.0-rc.1 (2020-06-29)

* Bug Fixes
  * Remove changes that were unintentionally included in build

## 8.0.0-rc.0 (2020-06-24)

* Enhancements
  * Cache environment config in application config (#393)
  * Allow configuring LoggerBackend to send all messages, not just exceptions (e.g. `Logger.error("I am an error message")`)

* Bug Fixes
  * fix request url port in payloads for HTTPS requests  (#391)

* Breaking Changes
  * Change default `included_environments` to only include `:prod` by default (#370)
  * Change default event send type to :none instead of :async (#341)
  * Make hackney an optional dependency, and simplify Sentry.HTTPClient behaviour (#400)
  * Use Logger.metadata for Sentry.Context, no longer return metadata values on set_* functions, and rename `set_http_context` to `set_request_context` (#401)
  * Move excluded exceptions from Sentry.Plug to Sentry.DefaultEventFilter (#402)
  * Remove Sentry.Plug and Sentry.Phoenix.Endpoint in favor of Sentry.PlugContext and Sentry.PlugCapture (#402)
  * Remove feedback form rendering and configuration (#402)
  * Logger metadata is now specified by key in LoggerBackend instead of enabled/disabled (#403)
  * Require Elixir 1.10 and optionally plug_cowboy 2.3 (#403)
  * `Sentry.capture_exception/1` now only accepts exceptions (#403)

## 7.2.4 (2020-03-09)

* Enhancements
  * Allow configuring gather feedback form for Sentry.Plug errors (#387)

## 7.2.3 (2020-02-27)

* Enhancements
  * Allow gathering feedback from Sentry.Plug errors (#385)

## 7.2.2 (2020-02-13)

* Bug Fixes
  * Ensure stacktrace is list in LoggerBackend (#380)

## 7.2.1 (2019-12-05)

* Bug Fixes
  * Improve documentation for `Sentry.Client.send_event/2` (#367)
  * Fix potential Logger deadlock (#372)
  * Pass the same exception for NoRouteError in `Sentry.Phoenix.Endpoint` (#376)
  * Handle new MFA for duplicate Plug errors (#377)
  * Update docs to recommend using application environment config for adding `Sentry.LoggerBackend` (#379)

## 7.2.0 (2019-10-23)

* Enhancements
  * Allow filtering of Events using `before_send_event` (#364)

* Bug Fixes
  * Remove newline from Logger for API error (#351)
  * Add docs for Sentry.Context (#352)
  * Avoid error duplication for Plug errors (#355)
  * Fix issue in Sentry.Sources docs around recompilation (#357)

## 7.1.0 (2019-06-11)

* Enhancements
  * Option to include `Logger.metadata` in `Sentry.LoggerBackend` (#338)
  * Send maximum length of args in stacktrace (#340)
  * Fix dialyzer warning when using Sentry.Phoenix.Endpoint (#344)

* Bug Fixes
  * Fix documentation error relating to File.cwd!() (#346)
  * Add parens to File.cwd!() in documentation (#347)
  * Check that DSN is binary (#348)

## 7.0.6 (2019-04-17)

* Enhancements
  * Allow configuring Sentry log level (#334)

## 7.0.5 (2019-04-05)

* Bug Fixes
  * Strip leading "Elixir." from module name on error type (#330)

## 7.0.4 (2019-02-12)

* Bug Fixes
  * Do not error if you cannot format the remote IP or port (#326)

## 7.0.3 (2018-11-14)

* Bug Fixes
  * Fix issue from using spawn\_link stacktrace (#315)
  * Relax plug\_cowboy versions (#314)

## 7.0.2 (2018-11-01)

* Bug Fixes
  * Fix sending Phoenix.Router.NoRouteError when using Sentry.Phoenix.Endpoint (#309)

## 7.0.1 (2018-10-01)

* Enhancements
  * Remove Poison from applications list (#306)

## 7.0.0 (2018-09-07)

* Enhancements
  * Implement `Sentry.LoggerBackend`

* Breaking Changes
  * Replace Poison with configurable JSON library
  * Require Elixir 1.7+
  * Remove `Sentry.Logger`

## 6.4.2 (2018-09-05)

* Enhancements
  * Add deps reporting back (#305 / #301)

## 6.4.1 (2018-07-26)

* Bug Fixes
  * Remove UUID dependency (#298)
  * Fix link in documentation (#300)

## 6.4.0 (2018-07-02)

* Enhancements
  * Add documentation detail around including source code (#287)
  * Document fingerprinting (#288)
  * Document `Sentry.Context` (#289)
  * Add CONTRIBUTING.md (#290)
  * Document cookie scrubber (#291)
  * Document testing with Sentry (#292)

* Bug Fixes
  * Change `report_deps` default value to false to avoid compiler bug (#285)
  * Limit size of messages (#293)
  * Use `elixir_uuid` instead of `uuid` (#295)

## 6.3.0 (2018-06-26)

* Enhancements
  * Use the stacktrace passed to Sentry.Event.transform_exception/2 when calling Exception.normalize/3 (#266)
  * Reduce Logger noise in HTTP Client (#274)
  * Use `Plug.Conn.get_peer_data/1` (#273)

* Bug Fixes
  * Add documentation for capturing arbitrary events (#272)
  * Fix typo in README.md (#277)

## 6.2.1 (2018-04-24)

* Enhancements
  * Accept public key DSNs (#263)

## 6.2.0 (2018-04-04)

* Enhancements
  * Allow overriding in Sentry.Plug (#261)
  * Implement Sentry.Phoenix.Endpoint to capture errors in Phoenix.Endpoint (#259)
* Bug Fixes
  * Fix sending events from remote\_console (#262)
  * Add filter option to configuration table in README (#255)
  * Default to not sending cookies, but allow configuration to send (#254)
  * Do not raise on invalid DSN (#218)

## 6.1.0 (2017-12-07)

* Enhancements
  * Elixir 1.6.0 formatted (#246)
  * Improve documentation around source code compilation (#242)
  * Update typespecs (#249)
  * Report errors from :kernel.spawn processes (#251)
* Bug Fixes
  * Fix doc typos (#245)
  * Remove Sentry.Event compile warning (#248)
  * Fix enable\_source\_code\_context configuration (#247)

## 6.0.5 (2017-12-07)

* Enhancements
  * Improve README documentation (#236)
  * Fix GenEvent warning (#237, #239)
* Bug Fixes
  * Fix error\_type reported in Sentry.Plug (#238)

## 6.0.4 (2017-11-20)

* Enhancements
  * Allow string for included_environments by splitting on commas (#234)
* Bug Fixes
  * Handle :error when sending test event (#228)

## 6.0.3 (2017-11-01)

* Enhancements
  * Fix tests for differing versions of Erlang/Elixir (#221)
* Bug Fixes
  * Fix invalid value for stacktrace via Event rendering layer (#224)

## 6.0.2 (2017-10-03)

* Enhancements
  * Improve Sentry.Logger documentation (#217)
* Bug Fixes
  * Handle Plug.Upload during scrubbing (#208)
  * Do not check DSN for source\_code\_path_pattern configuration (#211)
  * Fix culprit ambiguity (#214)

## 6.0.1 (2017-09-06)

* Bug Fixes
  * Fix filters and test mix task (#206)
* Enhancements
  * Improve README clarity (#202)

## 6.0.0 (2017-08-29)

See these [`5.0.0` to `6.0.0` upgrade instructions](https://gist.github.com/mitchellhenke/ffe2048e708fd7dd32d8d0a843daddf3) to update your existing app.

* Breaking Changes
  * Remove use\_error\_logger configuration (#196)
  * enable\_source\_code\_context is no longer required configuration (#201)
* Bug Fixes
  * Fix README error (#197)
  * Prevent overwriting server\_name option (#200)
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
