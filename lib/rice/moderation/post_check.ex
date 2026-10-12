defmodule Rice.Moderation.PostCheck do
  @moduledoc "事后补审过的贴文版本(uri + cid),每个版本只审一次。"
  use Rice.Schema

  schema "post_moderations" do
    field :uri, :string
    field :cid, :string
    field :verdict, :string
    field :reasons, {:array, :string}, default: []
    timestamps(updated_at: false)
  end
end
