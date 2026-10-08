defmodule Rice.Settings.Site do
  @moduledoc "全站配置,单行(原 t_global_config)。单例约束由数据库上的唯一索引保证。"
  use Rice.Schema

  schema "site_settings" do
    field :fund_scale, :integer, default: 0
    field :issued_grain_scale, :integer, default: 0
    field :proposal_approval_votes, :integer, default: 0

    has_many :documents, Rice.Settings.Document,
      foreign_key: :site_setting_id,
      preload_order: [asc: :position, asc: :id]

    timestamps()
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(site, attrs) do
    site
    |> cast(attrs, [:fund_scale, :issued_grain_scale, :proposal_approval_votes])
    |> validate_number(:fund_scale, greater_than_or_equal_to: 0)
    |> validate_number(:issued_grain_scale, greater_than_or_equal_to: 0)
    |> validate_number(:proposal_approval_votes, greater_than_or_equal_to: 0)
    |> unique_constraint(:id, name: :site_settings_singleton, message: "全站配置只能有一行")
  end
end
