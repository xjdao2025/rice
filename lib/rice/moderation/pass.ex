defmodule Rice.Moderation.Pass do
  @moduledoc "发布前审核通过的内容指纹,见 `Rice.Moderation.remember_pass/3`。"
  use Rice.Schema

  schema "moderation_passes" do
    field :fingerprint, :string
    timestamps(updated_at: false)
  end
end
