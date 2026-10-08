defmodule Rice.GrainsTest do
  use Rice.DataCase, async: true

  alias Rice.Grains
  alias Rice.Accounts.User

  defp balance(user), do: Rice.Repo.get!(User, user.id).grain_balance

  describe "transfer/4" do
    test "余额此消彼长,账本记一行" do
      from = user_fixture() |> give_grain(100)
      to = user_fixture()

      assert {:ok, transfer} = Grains.transfer(from, to, 30)

      assert balance(from) == 70
      assert balance(to) == 30
      assert transfer.amount == 30
      assert transfer.kind == "gift"
      assert Rice.Repo.aggregate(Grains.Transfer, :count) == 1
    end

    test "可以用 DID 指定收款方" do
      from = user_fixture() |> give_grain(100)
      to = user_fixture()

      assert {:ok, _} = Grains.transfer(from, to.did, 10)
      assert balance(to) == 10
    end

    test "余额不足时整笔回滚,账本不留痕" do
      from = user_fixture() |> give_grain(10)
      to = user_fixture()

      assert {:error, :insufficient_balance} = Grains.transfer(from, to, 11)

      assert balance(from) == 10
      assert balance(to) == 0
      assert Rice.Repo.aggregate(Grains.Transfer, :count) == 0
    end

    test "刚好花光是允许的" do
      from = user_fixture() |> give_grain(10)
      to = user_fixture()

      assert {:ok, _} = Grains.transfer(from, to, 10)
      assert balance(from) == 0
    end

    test "不能转给自己" do
      user = user_fixture() |> give_grain(100)
      assert {:error, :cannot_transfer_to_self} = Grains.transfer(user, user, 1)
      assert balance(user) == 100
    end

    test "收款方不存在 / 已禁用" do
      from = user_fixture() |> give_grain(100)
      disabled = user_fixture()
      Rice.Repo.update!(Ecto.Changeset.change(disabled, disabled_at: DateTime.utc_now()))

      assert {:error, :recipient_not_found} = Grains.transfer(from, "did:plc:nobody", 1)
      assert {:error, :recipient_disabled} = Grains.transfer(from, disabled.did, 1)
      assert balance(from) == 100
    end

    test "金额必须为正" do
      from = user_fixture() |> give_grain(100)
      to = user_fixture()

      for bad <- [0, -1, -100] do
        assert {:error, %Ecto.Changeset{}} = Grains.transfer(from, to, bad)
      end

      assert balance(from) == 100
    end

    # 这是换掉 Redis 分布式锁的关键验证。core 为此对付款方和收款方各
    # acquire 一次锁(5 秒超时);这里只有一条带条件的 UPDATE。
    test "并发扣款不会超支" do
      from = user_fixture() |> give_grain(100)
      to = user_fixture()
      parent = self()

      results =
        1..20
        |> Task.async_stream(
          fn _ ->
            Ecto.Adapters.SQL.Sandbox.allow(Rice.Repo, parent, self())
            Grains.transfer(from, to, 10)
          end,
          max_concurrency: 20,
          timeout: 30_000
        )
        |> Enum.map(fn {:ok, r} -> r end)

      succeeded = Enum.count(results, &match?({:ok, _}, &1))

      # 100 稻米、每次 10,最多成功 10 次 —— 不多不少
      assert succeeded == 10
      assert balance(from) == 0
      assert balance(to) == 100
      assert Rice.Repo.aggregate(Grains.Transfer, :count) == 10
    end

    test "余额永远不会变负 —— 数据库层还有一道 check" do
      user = user_fixture()

      assert_raise Ecto.ConstraintError, fn ->
        Rice.Repo.update!(Ecto.Changeset.change(user, grain_balance: -1))
      end
    end
  end

  describe "grant/3" do
    test "增发只加不减,没有付款方" do
      user = user_fixture()

      assert {:ok, transfer} = Grains.grant(user, 1000, memo: "首批发放")

      assert balance(user) == 1000
      assert transfer.kind == "grant"
      assert is_nil(transfer.from_user_id)
      assert transfer.memo == "首批发放"
    end

    # 生产实测:全站余额之和 == 发放总额 8,941,666。
    # reward/gift 是零和的内部转移,不改变总量。
    test "转账不改变总量,只有增发会" do
      a = user_fixture()
      b = user_fixture()

      {:ok, _} = Grains.grant(a, 500)
      {:ok, _} = Grains.grant(b, 300)
      assert %{balances: 800, granted: 800, ok?: true} = Grains.reconcile()

      {:ok, _} = Grains.transfer(Rice.Repo.get!(User, a.id), b, 200)
      assert %{balances: 800, granted: 800, ok?: true} = Grains.reconcile()
    end
  end

  describe "明细查询" do
    test "收和付都出现在自己的明细里" do
      me = user_fixture() |> give_grain(100)
      other = user_fixture()

      {:ok, _} = Grains.transfer(me, other, 10)
      {:ok, _} = Grains.grant(me, 50)
      {:ok, _} = Grains.transfer(Rice.Repo.get!(User, other.id), me, 5)

      page = Grains.list_transfers(me)
      assert length(page.entries) == 3
    end

    test "看不到与自己无关的流水" do
      me = user_fixture()
      a = user_fixture() |> give_grain(100)
      b = user_fixture()

      {:ok, _} = Grains.transfer(a, b, 10)

      assert Grains.list_transfers(me).entries == []
    end

    test "新的在前" do
      me = user_fixture()
      {:ok, first} = Grains.grant(me, 1)
      {:ok, second} = Grains.grant(me, 2)

      assert [^second, ^first] =
               Enum.map(Grains.list_transfers(me).entries, & &1.id)
               |> Enum.map(fn id -> Enum.find([second, first], &(&1.id == id)) end)
    end
  end
end
