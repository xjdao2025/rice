defmodule RiceWeb.Api.Admin.ProposalJSON do
  alias RiceWeb.Api.{ProposalCommentJSON, ProposalJSON}

  def index(%{page: page}) do
    %{data: Enum.map(page.entries, &data/1), meta: Rice.Pagination.meta(page)}
  end

  def show(%{proposal: proposal, comments: comments}) do
    comments = Enum.map(comments.entries, &ProposalCommentJSON.data/1)
    %{data: Map.put(data(proposal), :comments, comments)}
  end

  # C 端那份去掉"我投了什么",加上下架和软删 —— 后台要看得到才能复核
  defp data(proposal) do
    proposal
    |> ProposalJSON.data()
    |> Map.delete(:my_vote)
    |> Map.merge(%{listed: proposal.listed, deleted_at: proposal.deleted_at})
  end
end
