defmodule Rice.Moderation.ScanState do
  @moduledoc "持久化补审窗口及游标；失败重跑或超过单轮预算时不丢失积压。"
  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}
  @type t :: %__MODULE__{}
  schema "post_scan_states" do
    field :since, :utc_datetime_usec
    field :until, :utc_datetime_usec
    field :cursor, :string
    field :watermark, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end
end
