defmodule Rice.Settings do
  @moduledoc "全站配置(原 t_global_config)。单行。"
  import Ecto.Query

  alias Rice.Repo
  alias Rice.Settings.{Document, Site}

  @doc """
  取全站配置。库里没有行时返回一个全零的默认值,而不是 nil ——
  这样 `GET /api/settings/foundation` 在全新部署上也是 200 而不是 500。
  """
  @spec get_site() :: Site.t()
  def get_site do
    Repo.one(from s in Site, limit: 1, preload: [documents: :attachment]) ||
      %Site{documents: []}
  end

  @doc """
  改全站配置。core 分成 `modify-foundation-info` 和 `modify-proposal-config`
  两个接口,但改的是同一行 —— 这里是一个 PATCH。

  `document_ids` 给了就整份替换基金会公开文件的清单(顺序即展示顺序);
  不给就不动。库里还没有配置行时自动建一行,新部署不用先手动插数据。
  """
  @spec update_site(map()) :: {:ok, Site.t()} | {:error, Ecto.Changeset.t()}
  def update_site(attrs) do
    attrs = Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
    site = Repo.one(from s in Site, limit: 1) || %Site{}

    Ecto.Multi.new()
    |> Ecto.Multi.insert_or_update(:site, Site.changeset(site, attrs))
    |> replace_documents(attrs["document_ids"])
    |> Repo.transaction()
    |> case do
      {:ok, _} -> {:ok, get_site()}
      {:error, _step, reason, _} -> {:error, reason}
    end
  end

  defp replace_documents(multi, ids) when is_list(ids) do
    multi
    |> Ecto.Multi.delete_all(:clear_documents, fn %{site: site} ->
      from d in Document, where: d.site_setting_id == ^site.id
    end)
    |> Ecto.Multi.run(:documents, fn repo, %{site: site} ->
      ids
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, []}, fn {attachment_id, index}, {:ok, acc} ->
        changeset =
          Document.changeset(%Document{}, %{
            site_setting_id: site.id,
            attachment_id: attachment_id,
            position: index
          })

        case repo.insert(changeset) do
          {:ok, doc} -> {:cont, {:ok, [doc | acc]}}
          {:error, cs} -> {:halt, {:error, cs}}
        end
      end)
    end)
  end

  defp replace_documents(multi, _), do: multi
end
