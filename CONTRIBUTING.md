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
