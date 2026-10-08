defmodule RiceWeb.Api.ProposalCommentJSON do
  alias RiceWeb.Api.UserJSON

  def index(%{page: page}) do
    %{data: Enum.map(page.entries, &data/1), meta: %{next_cursor: page.next_cursor}}
  end

  def show(%{comment: comment}), do: %{data: data(comment)}

  def data(comment) do
    %{
      id: comment.id,
      body: comment.body,
      # core 在评论表上存了一份 user_name 副本;这里 join
      author: UserJSON.embed(comment.user),
      inserted_at: comment.inserted_at
    }
  end
end
