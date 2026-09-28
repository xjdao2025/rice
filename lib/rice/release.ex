defmodule Rice.Release do
  @moduledoc """
  Used for executing DB release tasks when run in production without Mix
  installed.
  """
  @app :rice

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  @doc """
  修正文里内嵌的 core 下载地址,见 `Rice.Import.EmbeddedFiles`。生产上没有 Mix:

      bin/rice eval 'Rice.Release.fix_embedded_files("/alloc/core", "https://rice.xjdao.xyz")'
      bin/rice eval 'Rice.Release.fix_embedded_files("/alloc/core", "https://rice.xjdao.xyz", true)'

  默认 dry-run。只起 Repo,不起整个应用 —— 否则会和正在跑的实例抢端口、抢 Oban 任务。
  """
  def fix_embedded_files(source_dir, base_url, commit? \\ false) do
    load_app()

    unless File.dir?(source_dir), do: raise("目录不存在:#{source_dir}")

    {:ok, result, _} =
      Ecto.Migrator.with_repo(Rice.Repo, fn _repo ->
        Rice.Import.EmbeddedFiles.run(source_dir, base_url, commit?)
      end)

    IO.puts(if commit?, do: "== 修正文内嵌地址(commit)==", else: "== 修正文内嵌地址(dry-run)==")
    for host <- result.hosts, do: IO.puts("  #{inspect(host)}")
    IO.puts("新搬入: #{result.files_copied}  复用已有: #{result.files_reused}")
    for m <- result.missing, do: IO.puts("  源文件缺失: #{inspect(m)}")
    for f <- result.failed, do: IO.puts("  失败: #{inspect(f)}")
    unless commit?, do: IO.puts("[dry-run] 未写入任何内容。")

    result
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    # Many platforms require SSL when connecting to the database
    Application.ensure_all_started(:ssl)
    Application.ensure_loaded(@app)
  end
end
