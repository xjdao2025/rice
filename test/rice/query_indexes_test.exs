defmodule Rice.QueryIndexesTest do
  use Rice.DataCase, async: true

  test "新增索引已建立并有效，覆盖个人凭证、验证码和列表投影" do
    indexes =
      Rice.Repo.query!("""
      SELECT c.relname, i.indisvalid, pg_get_indexdef(i.indexrelid)
      FROM pg_index i
      JOIN pg_class c ON c.oid = i.indexrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = current_schema()
      """).rows
      |> Map.new(fn [name, valid, definition] -> {name, {valid, definition}} end)

    for {name, columns} <- [
          {"grain_receipts_from_user_id_id_index", ["from_user_id", "id"]},
          {"verification_codes_channel_lower_target_inserted_at_index",
           ["channel", "lower(", "target", "inserted_at"]},
          {"event_applications_event_id_round_user_id_id_index",
           ["event_id", "round", "user_id", "id"]},
          {"task_submissions_pending_review_index",
           ["task_id", "round", "review_reason IS NULL", "final_status IS NULL"]}
        ] do
      assert {true, definition} = Map.fetch!(indexes, name)
      for column <- columns, do: assert(String.contains?(definition, column))
    end
  end
end
