defmodule Sentry.DSN do
  @moduledoc false

  @type t() :: %__MODULE__{
          original_dsn: String.t(),
          endpoint_uri: String.t(),
          public_key: String.t(),
          secret_key: String.t() | nil
        }

  defstruct [
    :original_dsn,
    :endpoint_uri,
    :public_key,
    :secret_key
  ]

  # {PROTOCOL}://{PUBLIC_KEY}:{SECRET_KEY}@{HOST}{PATH}/{PROJECT_ID}
  @spec parse(String.t()) :: {:ok, t()} | {:error, String.t()}
  def parse(term)

  def parse(dsn) when is_binary(dsn) do
    uri = URI.parse(dsn)

    if uri.query do
      raise ArgumentError, """
      using a Sentry DSN with query parameters is not supported since v9.0.0 of this library.
      The configured DSN was:

          #{inspect(dsn)}

      The query string in that DSN is:

          #{inspect(uri.query)}

      Please remove the query parameters from your DSN and pass them in as regular
      configuration. Check out the guide to upgrade to 9.0.0 at:

        https://hexdocs.pm/sentry/upgrade-9.x.html

      See the documentation for the Sentry module for more information on configuration
      in general.
      """
    end

    unless is_binary(uri.path) do
      throw("missing project ID at the end of the DSN URI: #{inspect(dsn)}")
    end

    unless is_binary(uri.userinfo) do
      throw("missing user info in the DSN URI: #{inspect(dsn)}")
    end

    {public_key, secret_key} =
      case String.split(uri.userinfo, ":", parts: 2) do
        [public, secret] -> {public, secret}
        [public] -> {public, nil}
      end

    with {:ok, {base_path, project_id}} <- pop_project_id(uri.path) do
      new_path = Enum.join([base_path, "api", project_id, "envelope"], "/") <> "/"
      endpoint_uri = URI.merge(%URI{uri | userinfo: nil}, new_path)

      parsed_dsn = %__MODULE__{
        endpoint_uri: URI.to_string(endpoint_uri),
        public_key: public_key,
        secret_key: secret_key,
        original_dsn: dsn
      }

      {:ok, parsed_dsn}
    end
  catch
    message -> {:error, message}
  end

  def parse(other) do
    {:error, "expected :dsn to be a string or nil, got: #{inspect(other)}"}
  end

  ## Helpers

  defp pop_project_id(uri_path) do
    path = String.split(uri_path, "/")
    {project_id, path} = List.pop_at(path, -1)

    case Integer.parse(project_id) do
      {_project_id, ""} ->
        {:ok, {Enum.join(path, "/"), project_id}}

      _other ->
        {:error, "expected the DSN path to end with an integer project ID, got: #{inspect(path)}"}
    end
  end
end
