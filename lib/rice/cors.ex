defmodule Rice.Cors do
  @moduledoc """
  允许跨域访问 rice API 的来源。

  C 端 app 和 rice 从来不同源(app 在 `xjdao.xyz`,rice 在 `rice.xjdao.xyz`),
  所以这不是开发期才需要的东西 —— 生产也靠它。

  (更正:这里原来写着"原生 app 不走 CORS,所以这个洞在真机上看不出来"。
  xjdao **没有原生 app**,只有 web —— `social-app` 是 Bluesky 的 fork,
  Expo/EAS 那套东西还在仓库里,但 `app.config.js` 至今是上游的,构建流水线
  只出 web 镜像。那句话是 CORS 的一般性质,不是这个项目的事实。)

  **不用 `*`。** 白名单意味着改域名要改配置,但 `*` 意味着任何网页都能拿着
  用户浏览器里的令牌来调这套 API。多一行配置换这个,划算。
  """

  @doc """
  白名单。`CORS_ORIGINS` 是逗号分隔的完整来源(带协议和端口)。

  没配的时候按环境给默认值:开发环境放行本地的几个前端端口,
  生产环境什么都不放行 —— 宁可让人发现"跨域被挡了"去补配置,
  也不要默默放行一个猜出来的域名。
  """
  @spec allowed_origins() :: [String.t()]
  def allowed_origins do
    case Application.get_env(:rice, :cors, [])[:origins] do
      nil -> []
      origins when is_list(origins) -> origins
      origins when is_binary(origins) -> parse(origins)
    end
  end

  @doc "把 `a,b` 这样的串拆成列表。空串和多余空格都丢掉。"
  @spec parse(term()) :: [String.t()]
  def parse(value) when is_binary(value) do
    value
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  def parse(_), do: []
end
