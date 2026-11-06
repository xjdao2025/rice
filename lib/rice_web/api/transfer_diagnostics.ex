defmodule RiceWeb.Api.TransferDiagnostics do
  @moduledoc false
  require Logger

  def log_failure(scope, {:error, %Ecto.Changeset{} = changeset}) do
    fields = changeset.errors |> Keyword.keys() |> Enum.uniq()

    Logger.warning(
      "grain_transfer_failed scope=#{scope} reason=validation fields=#{inspect(fields)}"
    )
  end

  def log_failure(scope, {:error, reason}) when is_atom(reason) do
    Logger.warning("grain_transfer_failed scope=#{scope} reason=#{reason}")
  end

  def log_failure(scope, _error) do
    Logger.warning("grain_transfer_failed scope=#{scope} reason=unknown")
  end
end
