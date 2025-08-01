defmodule Sentry.OpenTelemetry.VersionChecker do
  @moduledoc false

  @minimum_versions %{
    opentelemetry: "1.5.0",
    opentelemetry_api: "1.4.0",
    opentelemetry_exporter: "1.0.0",
    opentelemetry_semantic_conventions: "1.27.0"
  }

  @spec tracing_compatible?() :: boolean()
  def tracing_compatible? do
    case check_compatibility() do
      {:ok, :compatible} -> true
      {:error, _} -> false
    end
  end

  @spec check_compatibility() :: {:ok, :compatible} | {:error, term()}
  def check_compatibility do
    case check_all_dependencies() do
      [] ->
        {:ok, :compatible}

      errors ->
        {:error, {:incompatible_versions, errors}}
    end
  end

  defp check_all_dependencies do
    @minimum_versions
    |> Enum.flat_map(fn {dep, min_version} ->
      case check_dependency_version(dep, min_version) do
        :ok -> []
        {:error, reason} -> [{dep, reason}]
      end
    end)
  end

  defp check_dependency_version(dep, min_version) do
    case get_loaded_version(dep) do
      {:ok, loaded_version} ->
        if version_compatible?(loaded_version, min_version) do
          :ok
        else
          {:error, {:version_too_old, loaded_version, min_version}}
        end

      {:error, :not_loaded} ->
        {:error, :not_loaded}
    end
  end

  defp get_loaded_version(dep) do
    apps = Application.loaded_applications()

    case List.keyfind(apps, dep, 0) do
      {^dep, _description, version} ->
        {:ok, to_string(version)}

      nil ->
        {:error, :not_loaded}
    end
  end

  defp version_compatible?(loaded_version, min_version) do
    case Version.compare(loaded_version, min_version) do
      :gt -> true
      :eq -> true
      :lt -> false
    end
  end
end
