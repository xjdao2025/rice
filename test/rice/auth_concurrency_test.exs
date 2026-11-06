defmodule Rice.AuthConcurrencyTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  import Rice.Fixtures
  alias Ecto.Adapters.SQL.Sandbox
  alias Rice.{Accounts, Admin, Repo}
  alias Rice.Accounts.VerificationCode
  alias Rice.Admin.LoginAttempt

  test "独立连接同时试错不会覆盖管理员失败次数，也不会越过上限" do
    supervisor = start_supervised!(Task.Supervisor)

    Sandbox.unboxed_run(Repo, fn ->
      admin = admin_fixture()

      try do
        results =
          race(
            supervisor,
            for(
              _ <- 1..6,
              do: fn -> Admin.start_login(admin.phone_region, admin.phone, "wrong-password") end
            )
          )

        assert Enum.count(results, &(&1 == {:error, :invalid_credentials})) ==
                 LoginAttempt.max_attempts()

        assert Enum.count(results, &(&1 == {:error, :too_many_attempts})) == 1
        attempt = Repo.get_by!(LoginAttempt, phone_region: admin.phone_region, phone: admin.phone)
        assert attempt.attempts == LoginAttempt.max_attempts()
        assert attempt.locked_until

        assert {:error, :too_many_attempts} =
                 Admin.start_login(admin.phone_region, admin.phone, "admin-password")
      after
        Repo.delete_all(
          from a in LoginAttempt,
            where: a.phone == ^admin.phone and a.phone_region == ^admin.phone_region
        )

        Repo.delete!(admin)
      end
    end)
  end

  test "验证码在最后一次错误尝试处串行判定，不超次数；成功只消费一次" do
    supervisor = start_supervised!(Task.Supervisor)
    target = "concurrency-#{System.unique_integer([:positive])}@example.com"

    Sandbox.unboxed_run(Repo, fn ->
      record = Repo.insert!(VerificationCode.build("email", target, "register", "123456"))

      try do
        Repo.update!(Ecto.Changeset.change(record, attempts: VerificationCode.max_attempts() - 1))

        results =
          race(
            supervisor,
            for(
              _ <- 1..2,
              do: fn -> Accounts.verify_code("email", target, "register", "000000") end
            )
          )

        assert Enum.sort(results) ==
                 Enum.sort([{:error, :invalid_code}, {:error, :too_many_attempts}])

        assert Repo.get!(VerificationCode, record.id).attempts == VerificationCode.max_attempts()

        assert {:error, :too_many_attempts} =
                 Accounts.verify_code("email", target, "register", "123456")

        Repo.update_all(from(c in VerificationCode, where: c.id == ^record.id),
          set: [attempts: 0]
        )

        results =
          race(
            supervisor,
            for(
              _ <- 1..2,
              do: fn -> Accounts.verify_code("email", target, "register", "123456") end
            )
          )

        assert Enum.sort(results) == Enum.sort([:ok, {:error, :invalid_code}])
      after
        Repo.delete!(record)
      end
    end)
  end

  defp race(supervisor, actions) do
    parent = self()

    tasks =
      Enum.map(actions, fn action ->
        Task.Supervisor.async_nolink(supervisor, fn ->
          Sandbox.unboxed_run(Repo, fn ->
            send(parent, {:ready, self()})

            receive do
              :run -> action.()
            after
              5_000 -> raise "authentication barrier timed out"
            end
          end)
        end)
      end)

    workers =
      Enum.map(tasks, fn _ ->
        assert_receive {:ready, worker}, 5_000
        worker
      end)

    Enum.each(workers, &send(&1, :run))
    Enum.map(tasks, &Task.await(&1, 15_000))
  end
end
