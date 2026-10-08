defmodule RiceWeb.Api.ProposalVoteController do
  @moduledoc "投票。替代 core 的 /proposal/vote 和 /proposal/my-proposal-choice。"
  use RiceWeb, :controller

  alias Rice.Governance

  action_fallback RiceWeb.Api.FallbackController

  @doc "我在这个提案上投了什么。没投过返回 data: null。"
  def show(conn, %{"proposal_id" => proposal_id}) do
    with {:ok, proposal} <- Governance.fetch_proposal(proposal_id) do
      vote = Governance.get_my_vote(conn.assigns.current_user, proposal)
      json(conn, %{data: vote && %{choice: vote.choice, inserted_at: vote.inserted_at}})
    end
  end

  def create(conn, %{"proposal_id" => proposal_id} = params) do
    with {:ok, proposal} <- Governance.fetch_proposal(proposal_id) do
      case Governance.vote(conn.assigns.current_user, proposal, params["choice"]) do
        {:ok, vote} ->
          conn
          |> put_status(:created)
          |> json(%{data: %{choice: vote.choice, inserted_at: vote.inserted_at}})

        {:error, :proposal_closed} ->
          conn |> put_status(:unprocessable_entity) |> json(%{errors: %{detail: "投票已结束"}})

        {:error, :invalid_choice} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{errors: %{choice: ["只能是 agree 或 oppose"]}})

        error ->
          error
      end
    end
  end
end
