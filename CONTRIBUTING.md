## Contributing

Contributions to Sentry Elixir are encouraged and welcome from everyone.

Before submitting code, please run the test suite, format code according to Elixir's
code formatter and [Credo](https://github.com/rrrene/credo). This can be done with
`mix test`, `mix format` and `mix credo`.

The build server will also run [dialyzer](http://erlang.org/doc/man/dialyzer.html)
using [dialyxir](https://github.com/jeremyjh/dialyxir) to check the typespecs, but this can be onerous
to install and run. It is okay to submit changes without running it, but can
be run with `mix dialyzer` if you would like to run them yourself.

Once all checks are passing, you are ready to [open a pull request](https://help.github.com/articles/using-pull-requests/).

### Reviewing changes

Once a pull request is sent, the changes will be reviewed.

If any changes are necessary, maintainers will leave comments requesting changes
to the code. This does not guarantee a pull request will be accepted, as it will
be reviewed following each change.

Once the code is approved, your changes will be merged!

### Releasing a new version

(only relevant for Sentry employees)

Prerequisites:

- All changes that should be released must be in the `master` branch.

Manual Process:

- On GitHub in the `sentry-elixir` repository go to "Actions" select the "Release" workflow.
- Click on "Run workflow" on the right side and make sure the `master` branch is selected.
- Set "Version to release" input field. Here you decide if it is a major, minor or patch release.
- Click "Run Workflow"

This will trigger [Craft](https://github.com/getsentry/craft) to prepare everything needed for a release. (For more information see [craft prepare](https://github.com/getsentry/craft#craft-prepare-preparing-a-new-release)) At the end of this process, a release issue is created in the [Publish](https://github.com/getsentry/publish) repository. (Example release issue: https://github.com/getsentry/publish/issues/815)

Now one of the persons with release privileges (most probably your engineering manager) will review this Issue and then add the `accepted` label to the issue.

There are always two persons involved in a release.

If you are in a hurry and the release should be out immediately there is a Slack channel called `#proj-release-approval` where you can see your release issue and where you can ping people to please have a look immediately.

When the release issue is labeled `accepted` [Craft](https://github.com/getsentry/craft) is triggered again to publish the release to all the right platforms. (See [craft publish](https://github.com/getsentry/craft#craft-publish-publishing-the-release) for more information). At the end of this process, the release issue on GitHub will be closed and the release is completed! Congratulations!

There is a sequence diagram visualizing all this in the [README.md](https://github.com/getsentry/publish) of the `Publish` repository.
