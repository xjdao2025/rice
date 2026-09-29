defmodule Rice.Fixtures do
  @moduledoc """
  测试数据构造。刻意保持成朴素函数而不是引入 factory 库 —— 属性少的时候
  一个带默认值的 map merge 就够读了。
  """
  alias Rice.Repo
  import Ecto.Query

  def user_fixture(attrs \\ %{}) do
    n = System.unique_integer([:positive])

    attrs =
      Enum.into(attrs, %{
        did: "did:plc:test#{n}",
        handle: "user#{n}.web5.xjdao.test",
        nickname: "用户#{n}"
      })

    %Rice.Accounts.User{}
    |> Rice.Accounts.User.registration_changeset(attrs)
    |> Repo.insert!()
  end

  @doc "返回 {user, 明文令牌}。"
  def user_with_token(attrs \\ %{}) do
    user = user_fixture(attrs)
    {:ok, token} = Rice.Accounts.issue_token(user)
    {user, token}
  end

  def task_publisher_fixture(attrs \\ %{}) do
    publisher =
      attrs
      |> user_fixture()
      |> Ecto.Changeset.change(can_publish_tasks: true)
      |> Repo.update!()

    node_fixture(%{user_id: publisher.id})
    publisher
  end

  def funded_node_fixture(publisher, amount) do
    node = Repo.get_by!(Rice.Community.Node, user_id: publisher.id)
    {:ok, _} = Rice.Grains.grant(publisher, amount)
    {:ok, _} = Rice.Grains.fund_node(publisher, node, amount, "fixture-fund")
    Repo.get!(Rice.Community.Node, node.id)
  end

  def task_fixture(creator, attrs \\ %{}) do
    n = System.unique_integer([:positive])

    attrs =
      Enum.into(attrs, %{
        title: "任务#{n}",
        description: "完成任务#{n}的交付说明",
        organizer_contact: "社区服务台"
      })

    node_id =
      attrs[:node_id] ||
        (Repo.one(from n in Rice.Community.Node, where: n.user_id == ^creator.id, limit: 1) ||
           node_fixture(%{user_id: creator.id})).id

    %Rice.Tasks.Task{creator_id: creator.id, node_id: node_id}
    |> Rice.Tasks.Task.create_changeset(attrs)
    |> Repo.insert!()
  end

  def authed(conn, token), do: Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> token)

  def node_fixture(attrs \\ %{}) do
    n = System.unique_integer([:positive])
    attrs = Enum.into(attrs, %{name: "节点#{n}"})

    %Rice.Community.Node{}
    |> Rice.Community.Node.changeset(attrs)
    |> Repo.insert!()
  end

  def badge_fixture(attrs \\ %{}) do
    n = System.unique_integer([:positive])
    attrs = Enum.into(attrs, %{name: "勋章#{n}"})

    %Rice.Community.Badge{}
    |> Rice.Community.Badge.changeset(attrs)
    |> Repo.insert!()
  end

  @doc "直接给用户加余额,绕过账本 —— 只用于给测试铺初始状态。"
  def give_grain(user, amount) do
    Repo.update!(Ecto.Changeset.change(user, grain_balance: user.grain_balance + amount))
  end

  def proposal_fixture(user, attrs \\ %{}) do
    n = System.unique_integer([:positive])

    attrs =
      Enum.into(attrs, %{
        title: "提案#{n}",
        closes_at: DateTime.add(DateTime.utc_now(), 7 * 24 * 3600, :second)
      })

    %Rice.Governance.Proposal{user_id: user.id}
    |> Rice.Governance.Proposal.changeset(attrs)
    |> Repo.insert!()
  end

  @doc "返回管理员。默认 role=admin,密码 `admin-password`。"
  def admin_fixture(attrs \\ %{}) do
    n = System.unique_integer([:positive])

    attrs =
      Enum.into(attrs, %{
        phone: "138#{String.pad_leading(to_string(rem(n, 100_000_000)), 8, "0")}",
        phone_region: "86",
        nickname: "管理员#{n}",
        role: "admin",
        password: "admin-password"
      })

    %Rice.Admin.AdminUser{}
    |> Rice.Admin.AdminUser.changeset(attrs)
    |> Repo.insert!()
  end

  @doc "返回 {管理员, 明文令牌}。"
  def admin_with_token(attrs \\ %{}) do
    admin = admin_fixture(attrs)
    {:ok, token} = Rice.Admin.issue_token(admin)
    {admin, token}
  end

  def attachment_fixture(attrs \\ %{}) do
    attrs =
      Enum.into(attrs, %{
        kind: "image",
        filename: "封面.png",
        content_type: "image/png",
        byte_size: 1234
      })

    %Rice.Files.Attachment{}
    |> Rice.Files.Attachment.changeset(attrs)
    |> Repo.insert!()
  end

  def app_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{name: "国仁全球大学堂", url: "https://example.test"})

    %Rice.Content.App{}
    |> Rice.Content.App.changeset(attrs)
    |> Repo.insert!()
  end

  def banner_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{url: "https://example.test/post"})

    %Rice.Content.Banner{}
    |> Rice.Content.Banner.changeset(attrs)
    |> Repo.insert!()
  end

  def announcement_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{title: "乡建DAO社区公约"})

    %Rice.Content.Announcement{}
    |> Rice.Content.Announcement.changeset(attrs)
    |> Repo.insert!()
  end

  def site_settings_fixture(attrs \\ %{}) do
    attrs =
      Enum.into(attrs, %{
        fund_scale: 754_313,
        issued_grain_scale: 8_941_666,
        proposal_approval_votes: 20
      })

    %Rice.Settings.Site{}
    |> Rice.Settings.Site.changeset(attrs)
    |> Repo.insert!()
  end

  def site_document_fixture(site, attachment, position \\ 0) do
    %Rice.Settings.Document{}
    |> Rice.Settings.Document.changeset(%{
      site_setting_id: site.id,
      attachment_id: attachment.id,
      position: position
    })
    |> Repo.insert!()
  end
end
