# Upgrade to Sentry 10.x

This guide contains information on how to upgrade from Sentry `9.x` to Sentry `10.x`. If you're on a version lower than `9.x`, see the previous upgrade guides to get to `9.x` before going through this one.

## Actively Package Your Source Code

Before Sentry `10.0.0`, in order to report source code context around errors you had to configure Sentry through the `:enable_source_code_context`, `:root_source_code_paths`, and a few other options. These were **compile-time options**, meaning that if you changed any of these you had to recompile *the Sentry dependency itself*, not just your project. This was because Sentry used to store the raw source code of your application in its own compiled bytecode.

In Sentry `10.0.0`, we've revised this approach for a couple of reasons:

  * To avoid storing the raw source code in the compiled Sentry code, which in turn makes the BEAM bytecode artifact of your release smaller.

  * To simplify the compilation/recompilation step mentioned above.

Now, packaging source code is an active step that you have to take. The [`mix sentry.package_source_code`](`Mix.Tasks.Sentry.PackageSourceCode`) Mix task stores the source code in a compressed file inside the `priv` directory of the `:sentry` application. Sentry then loads this file when the `:sentry` application starts. This approach works well because users of Sentry are not interested in packaging source code within non-production environments, so this new task can be added to release scripts (or `Dockerfile`s, for example) only in production environments.

*All the configuration options related to source code remain the same*. See [the documentation in the `Sentry` module](Sentry.html#module-reporting-source-code).

### What Do I Have to Do?

  1. Add a call to `mix sentry.package_source_code` in your release script. This can be inside a `Dockerfile`, for example. Make sure to call this **before** `mix release`, so that the built release will include the packaged source code.

  1. That's all!
