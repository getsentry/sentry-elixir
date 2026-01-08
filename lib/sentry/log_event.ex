defmodule Sentry.LogEvent do
  @moduledoc """
  Represents a log event that can be sent to Sentry.

  Log events follow the Sentry Logs Protocol as defined in:
  <https://develop.sentry.dev/sdk/telemetry/logs/>

  This module is used internally by `Sentry.LogsHandler` to create structured
  log events from Erlang `:logger` events.
  """
  @moduledoc since: "12.0.0"

  alias Sentry.Config

  @type level :: :trace | :debug | :info | :warn | :error | :fatal

  @typedoc """
  A log event struct.
  """
  @type t :: %__MODULE__{
          level: level(),
          body: String.t(),
          timestamp: float(),
          trace_id: String.t() | nil,
          parent_span_id: String.t() | nil,
          attributes: map(),
          environment: String.t() | nil,
          release: String.t() | nil,
          server_name: String.t() | nil,
          template: String.t() | nil,
          parameters: list() | nil
        }

  @enforce_keys [:level, :body, :timestamp]
  defstruct [
    :level,
    :body,
    :timestamp,
    :trace_id,
    :parent_span_id,
    :environment,
    :release,
    :server_name,
    :template,
    :parameters,
    attributes: %{}
  ]

  @sdk_version Mix.Project.config()[:version]

  # Mapping from Logger levels to Sentry log levels and severity numbers
  # https://develop.sentry.dev/sdk/telemetry/logs/#log-severity-number
  @level_mapping %{
    emergency: {:fatal, 21},
    alert: {:fatal, 21},
    critical: {:fatal, 21},
    error: {:error, 17},
    warning: {:warn, 13},
    warn: {:warn, 13},
    notice: {:info, 9},
    info: {:info, 9},
    debug: {:debug, 5}
  }

  @doc """
  Creates a new log event from an Erlang `:logger` event.

  Optionally accepts parameters for message template interpolation.
  Parameters can be:
    - A list for positional `%s` placeholders: `["Jane", "NYC"]`
    - A map for named `%{key}` placeholders: `%{name: "Jane", city: "NYC"}`

  ## Examples

      iex> log_event = %{level: :info, msg: {:string, "Hello world"}, meta: %{}}
      iex> Sentry.LogEvent.from_logger_event(log_event, %{})
      %Sentry.LogEvent{
        level: :info,
        body: "Hello world",
        timestamp: _,
        attributes: %{}
      }

      # With positional parameters
      iex> log_event = %{level: :info, msg: {:string, "Hello %s"}, meta: %{}}
      iex> Sentry.LogEvent.from_logger_event(log_event, %{}, ["Jane"])
      %Sentry.LogEvent{body: "Hello Jane", template: "Hello %s", parameters: ["Jane"], ...}

      # With named parameters
      iex> log_event = %{level: :info, msg: {:string, "Hello %{name}"}, meta: %{}}
      iex> Sentry.LogEvent.from_logger_event(log_event, %{}, %{name: "Jane"})
      %Sentry.LogEvent{body: "Hello Jane", template: "Hello %{name}", parameters: ["Jane"], ...}
  """
  @spec from_logger_event(
          :logger.log_event(),
          map(),
          [String.t()] | %{optional(String.t()) => String.t()} | nil
        ) :: t()
  def from_logger_event(log_event, attrs \\ %{}, parameters \\ nil)

  def from_logger_event(%{level: log_level, msg: msg} = log_event, attrs, parameters) do
    {level, _severity_number} = Map.get(@level_mapping, log_level, {:info, 9})
    timestamp = extract_timestamp(log_event)

    # Extract message and potentially template/params from the msg
    # If user provided parameters via metadata, use those for interpolation
    {body, template, processed_params} = extract_message_with_template(msg, parameters)

    # Extract trace context if available, generate trace_id if not present
    {trace_id, parent_span_id} = extract_trace_context(log_event)
    trace_id = trace_id || Sentry.UUID.uuid4_hex()

    %__MODULE__{
      level: level,
      body: body,
      timestamp: timestamp,
      trace_id: trace_id,
      parent_span_id: parent_span_id,
      environment: Config.environment_name(),
      release: Config.release(),
      server_name: Config.server_name(),
      template: template,
      parameters: processed_params,
      attributes: attrs
    }
  end

  @doc """
  Converts a log event to a map suitable for JSON encoding.

  Other fields like environment, release, server_name, parent_span_id go into attributes
  with "sentry." prefix.
  """
  @spec to_map(t()) :: %{optional(atom()) => term()}
  def to_map(%__MODULE__{} = log_event) do
    %{
      timestamp: log_event.timestamp,
      level: to_string(log_event.level),
      body: log_event.body,
      trace_id: log_event.trace_id,
      attributes: build_attributes(log_event)
    }
  end

  ## Helpers

  # Interpolates placeholders in a message template with parameters
  # Supports both:
  #   - Positional: "Hello %s" with ["Jane"]
  #   - Named: "Hello %{name}" with %{name: "Jane"}
  # Returns {body, template, parameters} tuple
  defp interpolate_template(message, nil), do: {message, nil, nil}
  defp interpolate_template(message, []), do: {message, nil, nil}
  defp interpolate_template(message, params) when params == %{}, do: {message, nil, nil}

  # Positional parameters: %s placeholders
  defp interpolate_template(message, parameters) when is_list(parameters) do
    # Convert parameters to proper types for storage
    processed_params = Enum.map(parameters, &stringify_parameter/1)

    # Interpolate %s placeholders
    body = interpolate_positional_placeholders(message, parameters)

    {body, message, processed_params}
  end

  # Named parameters: %{key} placeholders
  defp interpolate_template(message, parameters) when is_map(parameters) do
    # Extract keys in the order they appear in the template
    keys = extract_named_placeholder_keys(message)

    # Convert to list of values in template order for storage
    processed_params =
      Enum.map(keys, fn key ->
        value = Map.get(parameters, key) || Map.get(parameters, to_string(key))
        stringify_parameter(value)
      end)

    # Interpolate %{key} placeholders
    body = interpolate_named_placeholders(message, parameters)

    {body, message, processed_params}
  end

  # Extract keys from %{key} placeholders in order of appearance
  defp extract_named_placeholder_keys(template) do
    ~r/%\{(\w+)\}/
    |> Regex.scan(template)
    |> Enum.map(fn [_, key] -> String.to_atom(key) end)
  end

  # Replace %s placeholders with parameter values (positional)
  defp interpolate_positional_placeholders(template, parameters) do
    {result, _remaining} =
      Enum.reduce(parameters, {template, parameters}, fn param, {tmpl, [_ | rest]} ->
        param_str = to_string_for_interpolation(param)
        new_tmpl = String.replace(tmpl, "%s", param_str, global: false)
        {new_tmpl, rest}
      end)

    result
  end

  # Replace %{key} placeholders with parameter values (named)
  defp interpolate_named_placeholders(template, parameters) do
    Regex.replace(~r/%\{(\w+)\}/, template, fn _, key ->
      atom_key = String.to_atom(key)
      value = Map.get(parameters, atom_key) || Map.get(parameters, key)
      to_string_for_interpolation(value)
    end)
  end

  defp to_string_for_interpolation(value) when is_binary(value), do: value
  defp to_string_for_interpolation(value) when is_atom(value), do: Atom.to_string(value)
  defp to_string_for_interpolation(value) when is_integer(value), do: Integer.to_string(value)
  defp to_string_for_interpolation(value) when is_float(value), do: Float.to_string(value)
  defp to_string_for_interpolation(value), do: inspect(value)

  # Convert parameter values to a form suitable for Sentry attributes
  # Note: is_boolean must come before is_atom since true/false are atoms
  defp stringify_parameter(value) when is_binary(value), do: value
  defp stringify_parameter(value) when is_boolean(value), do: value
  defp stringify_parameter(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify_parameter(value) when is_integer(value), do: value
  defp stringify_parameter(value) when is_float(value), do: value
  defp stringify_parameter(value), do: inspect(value)

  # Extract message body and optionally template/parameters
  # If user_params provided via metadata, use those for interpolation
  # Otherwise, capture template info from Erlang format strings

  # String message with user-provided parameters
  defp extract_message_with_template({:string, chardata}, user_params)
       when not is_nil(user_params) do
    message = IO.chardata_to_string(chardata)
    interpolate_template(message, user_params)
  end

  # Plain string message without parameters
  defp extract_message_with_template({:string, chardata}, nil) do
    {IO.chardata_to_string(chardata), nil, nil}
  end

  # Report messages - no template support
  defp extract_message_with_template({:report, report}, _user_params) when is_map(report) do
    {inspect(report), nil, nil}
  end

  defp extract_message_with_template({:report, report}, _user_params) when is_list(report) do
    {report |> Map.new() |> inspect(), nil, nil}
  end

  # Erlang format string with args - capture as template
  defp extract_message_with_template({format, args}, _user_params)
       when is_list(format) and is_list(args) do
    body = format |> :io_lib.format(args) |> IO.chardata_to_string()
    template = IO.chardata_to_string(format)
    processed_params = Enum.map(args, &stringify_parameter/1)
    {body, template, processed_params}
  end

  defp extract_message_with_template(_other, _user_params), do: {"", nil, nil}

  # Convert from microseconds to seconds (float)
  defp extract_timestamp(%{meta: %{time: time}}) do
    time / 1_000_000
  end

  # Extracts OpenTelemetry trace context from logger metadata.
  # The opentelemetry_logger_metadata package adds trace_id and span_id
  # as hex strings when logging inside OpenTelemetry spans.
  defp extract_trace_context(%{meta: %{trace_id: trace_id, span_id: span_id}})
       when is_binary(trace_id) and is_binary(span_id) do
    {trace_id, span_id}
  end

  defp extract_trace_context(_log_event), do: {nil, nil}

  defp build_attributes(%__MODULE__{} = log_event) do
    # Start with user-provided attributes
    formatted_attrs =
      Enum.into(log_event.attributes, %{}, fn {key, value} ->
        {to_string(key), %{value: value, type: attribute_type(value)}}
      end)

    # Add Sentry-specific attributes
    formatted_attrs
    |> put_sentry_attr("sentry.sdk.name", "sentry.elixir")
    |> put_sentry_attr("sentry.sdk.version", @sdk_version)
    |> put_sentry_attr_if("sentry.environment", log_event.environment)
    |> put_sentry_attr_if("sentry.release", log_event.release)
    |> put_sentry_attr_if("sentry.address", log_event.server_name)
    |> put_sentry_attr_if("sentry.trace.parent_span_id", log_event.parent_span_id)
    |> put_message_template_attrs(log_event.template, log_event.parameters)
  end

  # Add message template and parameter attributes when present
  defp put_message_template_attrs(attrs, nil, _parameters), do: attrs
  defp put_message_template_attrs(attrs, _template, nil), do: attrs
  defp put_message_template_attrs(attrs, _template, []), do: attrs

  defp put_message_template_attrs(attrs, template, parameters) when is_list(parameters) do
    attrs
    |> put_sentry_attr("sentry.message.template", template)
    |> put_parameter_attrs(parameters)
  end

  defp put_parameter_attrs(attrs, parameters) do
    parameters
    |> Enum.with_index()
    |> Enum.reduce(attrs, fn {value, index}, acc ->
      put_sentry_attr(acc, "sentry.message.parameter.#{index}", value)
    end)
  end

  defp put_sentry_attr(attrs, key, value) do
    Map.put(attrs, key, %{value: value, type: attribute_type(value)})
  end

  defp put_sentry_attr_if(attrs, _key, nil), do: attrs

  defp put_sentry_attr_if(attrs, key, value) do
    Map.put(attrs, key, %{value: value, type: attribute_type(value)})
  end

  defp attribute_type(value) when is_boolean(value), do: "boolean"
  defp attribute_type(value) when is_integer(value), do: "integer"
  defp attribute_type(value) when is_float(value), do: "double"
  defp attribute_type(_value), do: "string"
end
