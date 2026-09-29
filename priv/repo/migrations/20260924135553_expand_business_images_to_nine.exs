defmodule Rice.Repo.Migrations.ExpandBusinessImagesToNine do
  use Ecto.Migration

  def change do
    for {table, name} <- [
          {"task_images", "task_image_position"},
          {"event_images", "event_image_position"}
        ] do
      execute(
        "ALTER TABLE #{table} DROP CONSTRAINT #{name}, ADD CONSTRAINT #{name} CHECK (position >= 0 AND position < 9)",
        "ALTER TABLE #{table} DROP CONSTRAINT #{name}, ADD CONSTRAINT #{name} CHECK (position >= 0 AND position < 4)"
      )
    end
  end
end
