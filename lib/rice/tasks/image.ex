defmodule Rice.Tasks.Image do
  @moduledoc "任务正文图片的显示顺序；文件由 Rice.Files 保管。"
  use Rice.Schema

  schema "task_images" do
    belongs_to :task, Rice.Tasks.Task
    belongs_to :attachment, Rice.Files.Attachment
    field :position, :integer
  end
end
