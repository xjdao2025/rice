defmodule RiceWeb.Api.ProposalJSON do
  alias RiceWeb.Api.{AttachmentJSON, UserJSON}

  def index(%{page: page} = assigns) do
    votes = my_votes(assigns)

    %{
      data: Enum.map(page.entries, &data(&1, votes)),
      meta: %{next_cursor: page.next_cursor}
    }
  end

  def show(%{proposal: proposal} = assigns),
    do: %{data: data(proposal, my_votes(assigns))}

  def data(proposal, my_votes \\ %{}) do
    %{
      id: proposal.id,
      title: proposal.title,
      status: proposal.status,
      closes_at: proposal.closes_at,
      agree_count: proposal.agree_count,
      oppose_count: proposal.oppose_count,
      # core 另存了一个 total_votes 列;这里现算,不会出现三份不一致
      total_votes: proposal.agree_count + proposal.oppose_count,
      # 当前用户在这条提案上投了什么;未登录或没投过是 null。
      # core 把它塞在列表 VO 的 `choice` 里(0 表示没投),这里用 null。
      my_vote: Map.get(my_votes, proposal.id),
      attachment: AttachmentJSON.embed(proposal.attachment),
      author: UserJSON.embed(proposal.user),
      inserted_at: proposal.inserted_at
    }
  end

  defp my_votes(assigns), do: Map.get(assigns, :my_votes) || %{}
end
