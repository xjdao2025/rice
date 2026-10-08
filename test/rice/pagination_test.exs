defmodule Rice.PaginationTest do
  @moduledoc """
  两种分页模式。

  游标那套原本就有(散在各个控制器测试里),这里盯的是新加的页码模式,
  以及一件容易出错的事:**默认行为不能变**。C 端信息流全靠游标,
  哪天 `params/1` 开始默认返回 `page: 1`,所有信息流就会静默变成
  "永远第一页"。
  """
  use Rice.DataCase, async: true

  alias Rice.Accounts.User
  alias Rice.Pagination

  defp seed(n) do
    for i <- 1..n, do: user_fixture(%{nickname: "用户#{i}"})
  end

  defp query, do: from(u in User, where: is_nil(u.deleted_at))

  describe "参数解析" do
    test "不传 page 就是游标模式" do
      opts = Pagination.params(%{})

      assert opts.page == nil
      assert opts.limit == Pagination.default_limit()
    end

    test "传了 page 才进页码模式" do
      assert Pagination.params(%{"page" => "3"}).page == 3
      assert Pagination.params(%{"page" => 3}).page == 3
    end

    # 页码坏了退回第 1 页,和坏游标退回第一页是同一个取舍
    test "非法的 page 当第 1 页,不报错" do
      for bad <- ["0", "-1", "abc", "2.5", 0, -7] do
        assert Pagination.params(%{"page" => bad}).page == 1, "page=#{inspect(bad)}"
      end
    end

    test "per_page 和 limit 一样受上限约束" do
      assert Pagination.params(%{"per_page" => "15"}).limit == 15
      assert Pagination.params(%{"per_page" => "999"}).limit == Pagination.max_limit()
      assert Pagination.params(%{"per_page" => "0"}).limit == Pagination.default_limit()
    end

    test "per_page 优先于 limit" do
      assert Pagination.params(%{"per_page" => "5", "limit" => "50"}).limit == 5
    end
  end

  describe "页码模式" do
    test "分页取数,total 是全量而不是本页" do
      seed(7)

      page =
        Pagination.paginate(query(), Repo, Pagination.params(%{"page" => "1", "per_page" => "3"}))

      assert length(page.entries) == 3
      assert page.total == 7
      assert page.page == 1
      assert page.per_page == 3
    end

    test "翻到中间那页" do
      users = seed(7)
      # 默认按 id 倒序,所以第 2 页是第 4~6 新的
      expected = users |> Enum.reverse() |> Enum.slice(3, 3) |> Enum.map(& &1.id)

      page =
        Pagination.paginate(query(), Repo, Pagination.params(%{"page" => "2", "per_page" => "3"}))

      assert Enum.map(page.entries, & &1.id) == expected
    end

    test "翻过头是空页,不是报错也不是最后一页" do
      seed(3)

      page =
        Pagination.paginate(
          query(),
          Repo,
          Pagination.params(%{"page" => "99", "per_page" => "10"})
        )

      assert page.entries == []
      assert page.total == 3
      assert page.next_cursor == nil
    end

    test "最后一页没有 next_cursor" do
      seed(6)
      opts = fn p -> Pagination.params(%{"page" => p, "per_page" => "3"}) end

      assert Pagination.paginate(query(), Repo, opts.("1")).next_cursor != nil
      assert Pagination.paginate(query(), Repo, opts.("2")).next_cursor == nil
    end

    test "带 preload 的查询也能数出 total —— COUNT 不认 preload" do
      seed(3)
      q = from(u in User, where: is_nil(u.deleted_at), preload: [:avatar])

      page = Pagination.paginate(q, Repo, Pagination.params(%{"page" => "1", "per_page" => "2"}))

      assert page.total == 3
    end

    # Ecto 的 aggregate 遇到 group_by 直接抛 —— 勋章列表就是这样一个查询,
    # 它在页码模式下会 500
    test "带 group_by 的查询也能数出 total" do
      for _ <- 1..3, do: badge_fixture()

      q =
        from(b in Rice.Community.Badge,
          left_join: a in assoc(b, :awards),
          group_by: b.id,
          select: %{b | holder_count: count(a.id)}
        )

      page = Pagination.paginate(q, Repo, Pagination.params(%{"page" => "1", "per_page" => "2"}))

      assert length(page.entries) == 2
      assert page.total == 3
    end

    # 去掉 group_by 之后,一枚有 3 个持有人的勋章会变成 3 行。
    # 不去重的话 total 数的是连接后的行数,不是勋章数。
    test "连接出重复行时 total 数的是主表的行数" do
      badge = badge_fixture()
      for _ <- 1..3, do: {:ok, _} = Rice.Community.award_badge(badge, user_fixture())
      badge_fixture()

      q =
        from(b in Rice.Community.Badge,
          left_join: a in assoc(b, :awards),
          group_by: b.id,
          select: %{b | holder_count: count(a.id)}
        )

      page = Pagination.paginate(q, Repo, Pagination.params(%{"page" => "1", "per_page" => "10"}))

      assert page.total == 2
    end

    test "一条都没有时 total 是 0" do
      page = Pagination.paginate(query(), Repo, Pagination.params(%{"page" => "1"}))

      assert page.entries == []
      assert page.total == 0
      assert page.next_cursor == nil
    end
  end

  describe "游标模式没有被改坏" do
    test "默认仍然是游标,响应里不该冒出 total" do
      seed(3)

      page = Pagination.paginate(query(), Repo, Pagination.params(%{"limit" => "2"}))

      assert length(page.entries) == 2
      assert page.next_cursor != nil
      refute Map.has_key?(page, :total)
      refute Map.has_key?(page, :page)
    end

    test "游标翻页仍然衔接得上" do
      seed(5)
      first = Pagination.paginate(query(), Repo, Pagination.params(%{"limit" => "2"}))

      second =
        Pagination.paginate(
          query(),
          Repo,
          Pagination.params(%{"limit" => "2", "before" => first.next_cursor})
        )

      first_ids = Enum.map(first.entries, & &1.id)
      second_ids = Enum.map(second.entries, & &1.id)
      assert length(second_ids) == 2
      assert first_ids -- second_ids == first_ids
      # 游标是降序的:第二页全都比第一页的最后一个早
      assert Enum.all?(second_ids, &(&1 < List.last(first_ids)))
    end
  end

  describe "meta/1" do
    test "游标模式只给 next_cursor" do
      assert Pagination.meta(%{entries: [], next_cursor: "abc"}) == %{next_cursor: "abc"}
    end

    test "页码模式把 total 一起给出去 —— 少了它前端分页器只剩一页" do
      meta =
        Pagination.meta(%{entries: [], next_cursor: nil, total: 42, page: 2, per_page: 15})

      assert meta == %{next_cursor: nil, total: 42, page: 2, per_page: 15}
    end
  end
end
