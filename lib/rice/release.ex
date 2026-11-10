defmodule Rice.Release do
  @moduledoc """
  Used for executing DB release tasks when run in production without Mix
  installed.
  """
  @app :rice

  @spec migrate() :: [{:ok, [integer()], [atom()]}]
  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  @spec rollback(module(), integer()) :: {:ok, [integer()], [atom()]}
  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  @doc "Runs an explicit Point ledger operation with the repository started."
  @spec point_ledger(String.t()) :: :ok
  def point_ledger(action) do
    load_app()

    {:ok, result, _} =
      Ecto.Migrator.with_repo(Rice.Repo, fn _ -> run_point_action(action) end)

    case result do
      {:ok, data} -> IO.puts(Jason.encode!(%{ok: true, data: data}, pretty: true))
      {:error, reason} -> raise "Point ledger operation failed: #{inspect(reason)}"
    end
  end

  defp run_point_action("audit"), do: {:ok, Rice.Points.LegacySnapshot.audit()}

  defp run_point_action("bootstrap") do
    attrs = System.fetch_env!("POINT_BOOTSTRAP") |> Jason.decode!()

    case Rice.Points.Issuers.bootstrap(
           Map.fetch!(attrs, "community_id"),
           Map.fetch!(attrs, "code"),
           Map.get(attrs, "supply_cap"),
           Map.fetch!(attrs, "threshold"),
           Map.fetch!(attrs, "signers")
         ) do
      {:ok, point} -> {:ok, %{point_id: point.id, status: point.status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp run_point_action("prepare-legacy-rice") do
    with {:ok, point} <-
           Rice.Points.Issuers.prepare_legacy_rice(System.fetch_env!("POINT_LEGACY_COMMUNITY_ID")) do
      {:ok, %{point_id: point.id, status: point.status}}
    end
  end

  defp run_point_action("activate"),
    do: Rice.Points.LegacyCutover.activate(System.fetch_env!("POINT_CUTOVER_ID"))

  defp run_point_action("report"),
    do: Rice.Points.LegacyCutover.rollback_report(System.fetch_env!("POINT_CUTOVER_ID"))

  defp run_point_action("rollback-before-writes"),
    do: Rice.Points.LegacyCutover.rollback_before_writes(System.fetch_env!("POINT_CUTOVER_ID"))

  defp run_point_action("rollback-replay") do
    id = System.fetch_env!("POINT_CUTOVER_ID")
    reviewed = System.fetch_env!("POINT_REVIEWED_TRANSACTIONS") |> Jason.decode!()
    Rice.Points.LegacyCutover.rollback_with_replay(id, reviewed)
  end

  defp run_point_action("ensure-wallet") do
    attrs = System.fetch_env!("POINT_WALLET") |> Jason.decode!()
    point_id = Map.fetch!(attrs, "point_id")
    owner_id = Map.fetch!(attrs, "owner_id")

    owner =
      case Map.fetch!(attrs, "owner_type") do
        "user" -> owner_id
        "node" -> {:node, owner_id}
        _ -> nil
      end

    with true <- is_binary(point_id) and Rice.Tsid.valid?(point_id),
         %Rice.Points.Point{} <- Rice.Repo.get(Rice.Points.Point, point_id),
         {:ok, wallet} <- Rice.Points.WalletAccounts.ensure_recipient(point_id, owner) do
      {:ok, %{account_id: wallet.id, point_id: wallet.point_id}}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :point_not_found}
    end
  end

  defp run_point_action("bootstrap-spend-policy") do
    attrs = System.fetch_env!("POINT_SPEND_POLICY") |> Jason.decode!()

    with {:ok, policy} <-
           Rice.Points.bootstrap_spend_policy(
             Map.fetch!(attrs, "point_id"),
             Map.fetch!(attrs, "account_id"),
             Map.fetch!(attrs, "threshold"),
             Map.fetch!(attrs, "signers")
           ) do
      {:ok, %{policy_id: policy.id, version: policy.version, account_id: policy.account_id}}
    end
  end

  defp run_point_action("register-payment-app") do
    attrs = System.fetch_env!("POINT_PAYMENT_APP") |> Jason.decode!()

    case Rice.Points.Payments.register_app(
           Map.fetch!(attrs, "name"),
           Map.fetch!(attrs, "payee_account_id"),
           Map.fetch!(attrs, "return_url")
         ) do
      {:ok, %{app: app, credential: credential}} ->
        {:ok, %{app_id: app.id, credential: credential}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_point_action("rotate-payment-credential") do
    id = System.fetch_env!("POINT_PAYMENT_APP_ID")

    with {:ok, credential} <- Rice.Points.Payments.rotate_credential(id) do
      {:ok, %{app_id: id, credential: credential}}
    end
  end

  defp run_point_action(action) when action in ["enable-payment-app", "disable-payment-app"] do
    id = System.fetch_env!("POINT_PAYMENT_APP_ID")

    with {:ok, app} <- Rice.Points.Payments.set_active(id, action == "enable-payment-app") do
      {:ok, %{app_id: app.id, active: app.active}}
    end
  end

  defp run_point_action(_), do: {:error, :unknown_point_ledger_action}

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    # Many platforms require SSL when connecting to the database
    Application.ensure_all_started(:ssl)
    Application.ensure_loaded(@app)
  end
end
