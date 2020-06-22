defmodule Sentry.CrashError do
  defexception [:message]

  def exception({:nocatch, reason}) do
    %Sentry.CrashError{message: Exception.format_banner(:throw, reason, [])}
  end

  def exception(reason) do
    %Sentry.CrashError{message: Exception.format_banner(:exit, reason, [])}
  end
end
