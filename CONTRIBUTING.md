# Contributing to the Sentry SDK for Elixir

We welcome contributions to `sentry-elixir` by the community. See the [Contributing to Docs](https://docs.sentry.io/contributing/) page if you want to fix or update the documentation on the website.

## How to Report a Problem

Please search the [issue tracker][issues] before creating a new issue (a problem or an improvement request). Please also ask in our [Sentry Community on Discord](https://discord.com/invite/Ww9hbqr) before submitting a new issue. There is a ton of great people in our Discord community ready to help you!

If you feel that you can fix or implement it yourself, please read a few paragraphs below to learn how to submit your changes.

## Submitting Changes

  * Set up the development environment.
  * Clone `sentry-elixir` and prepare necessary changes.
  * Add tests for your changes to `test/`.
  * Run tests and make sure all of them pass.
  * Submit a pull request, referencing any issues it addresses.

We will review your pull request as soon as possible. Thank you for contributing!

## Development Environment

### Clone the Repo

```bash
git clone git@github.com:getsentry/sentry-elixir.git
```

### Install Elixir and Fetch Dependencies

Make sure that you have Elixir 1.15.x installed. Follow the official [Elixir installation guide](https://elixir-lang.org/install.html).

Then, run this in your shell from the root of the cloned repository:

```bash
mix deps.get
```

You're ready to make changes.

## Running Tests

Before submitting code, please run the test suite and format code according to Elixir's code formatter. This can be done with:

```bash
mix test
mix format
```

CI will also run [dialyzer](http://erlang.org/doc/man/dialyzer.html) using the [Dialyxir library](https://github.com/jeremyjh/dialyxir) to check the typespecs, but this can be onerous to install and run. It is okay to submit changes without running it. If you want to run it locally, run:

```bash
mix dialyzer
```

Once all checks are passing locally, you are ready to [open a pull request](https://help.github.com/articles/using-pull-requests/).

That's it. You should be ready to make changes, run tests, and make commits! If you experience any problems, please don't hesitate to ping us in our [Discord Community](https://discord.com/invite/Ww9hbqr).

## Releasing a New Version

*(Only relevant for Sentry employees)*.

Prerequisites:

  * All changes that should be released must be in the `master` branch.

Manual Process:

  * [On GitHub][repo], go to "Actions" and select the "Release" workflow.
  * Click on "Run workflow" on the right side and make sure the `master` branch is selected.
  * Set "Version to release" input field. Here you decide if it is a major, minor or patch release.
  * Click "Run Workflow".

This will trigger [Craft] to prepare everything needed for a release. (For more information see [craft prepare](https://github.com/getsentry/craft#craft-prepare-preparing-a-new-release)) At the end of this process, a release issue is created in the [`publish` repository][publish-repo]. (Example release issue: <https://github.com/getsentry/publish/issues/815>)

Now one of the persons with release privileges (most probably your engineering manager) will review this Issue and then add the `accepted` label to the issue.

There are always two persons involved in a release.

If you are in a hurry and the release should be out immediately there is a Slack channel called `#proj-release-approval` where you can see your release issue and where you can ping people to please have a look immediately.

When the release issue is labeled `accepted` [Craft] is triggered again to publish the release to all the right platforms. (See [craft publish](https://github.com/getsentry/craft#craft-publish-publishing-the-release) for more information). At the end of this process, the release issue on GitHub will be closed and the release is completed! Congratulations!

There is a sequence diagram visualizing all this in the [README.md][publish-repo] of the `Publish` repository.

### Versioning Policy

This project follows the [SemVer specification](https://semver.org/), with three additions:

  * SemVer says that major version `0` can include breaking changes at any time. Still, it is common practice to assume that only `0.x` releases (minor versions) can contain breaking changes while `0.x.y` releases (patch versions) are used for backwards-compatible changes (bug fixes and features). This project also follows that practice.

  * All undocumented APIs are to be considered internal. They are not part of this contract.

  * Certain features (such as integrations) may be explicitly called out as "experimental" or "unstable" in the documentation. They come with their own versioning policy described in the documentation.

A major release `N` implies the previous release `N-1` will no longer receive updates. We generally do not backport bug fixes to older versions unless they are security relevant. However, feel free to ask for backports of specific commits on the issue tracker.

## Commit Message Guidelines

See the documentation on commit messages here:

<https://develop.sentry.dev/commit-messages/#commit-message-format>

[repo]: https://github.com/getsentry/sentry-elixir
[issues]: https://github.com/getsentry/sentry-elixir/issues
[Craft]: https://github.com/getsentry/craft
[publish-repo]: https://github.com/getsentry/publish
