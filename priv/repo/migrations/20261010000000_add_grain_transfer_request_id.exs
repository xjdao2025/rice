defmodule Rice.Repo.Migrations.AddGrainTransferRequestId do
  @moduledoc """
  转账 / 打赏的重试标识。网络超时后带同一个 `request_id` 重试,只会记一笔。
  """
  use Ecto.Migration

  def change do
    alter table(:grain_transfers) do
      add :request_id, :string, size: 128
    end

    create unique_index(:grain_transfers, [:from_user_id, :request_id],
             where: "request_id IS NOT NULL",
             name: :grain_transfers_request_id
           )
  end
end
