defmodule Rice.Events.Image do
  @moduledoc "活动正文图片的显示顺序；文件由 Rice.Files 保管。"
  use Rice.Schema

  schema "event_images" do
    belongs_to :event, Rice.Events.Event
    belongs_to :attachment, Rice.Files.Attachment
    field :position, :integer
  end
end
