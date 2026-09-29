defmodule Rice.Repo.Migrations.AddBusinessContactFields do
  use Ecto.Migration

  def change do
    # Keep deployed records readable; new publish/apply requests validate presence.
    for name <- [:tasks, :events] do
      alter table(name) do
        add :organizer_contact, :string, size: 256
      end
    end

    for name <- [:task_applications, :event_applications] do
      alter table(name) do
        add :contact, :string, size: 256
      end
    end
  end
end
