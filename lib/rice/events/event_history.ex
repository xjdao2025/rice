defmodule Rice.Events.EventHistory do
  @moduledoc "活动的追加式业务记录，不存申请理由和用户资金余额。"
  use Rice.Schema

  schema "event_history" do
    field :action, :string
    field :from_status, :string
    field :to_status, :string
    field :round, :integer, default: 1
    field :before, :map
    field :after, :map
    belongs_to :event, Rice.Events.Event
    belongs_to :application, Rice.Events.Application
    belongs_to :actor, Rice.Accounts.User
    timestamps(updated_at: false)
  end
end
