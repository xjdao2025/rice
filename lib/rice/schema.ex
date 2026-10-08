defmodule Rice.Schema do
  @moduledoc """
  所有业务 schema 的公共前言。约定:

    * 主键是 `Rice.Tsid.Type`,自动生成(见 `Rice.Tsid`)
    * 外键同样是 TSID
    * 时间戳是 `inserted_at` / `updated_at`,`utc_datetime_usec`(Phoenix 惯例)
    * 每个 schema 自带 `@type t :: %__MODULE__{}`,`@spec` 里写 `User.t()`

  用法:

      defmodule Rice.Accounts.User do
        use Rice.Schema

        schema "users" do
          field :handle, :string
          timestamps()
        end
      end
  """
  defmacro __using__(_opts) do
    quote do
      use Ecto.Schema
      import Ecto.Changeset
      import Ecto.Query, only: [from: 2]
      import Rice.Schema, only: [trim: 1, optional_trim: 1]

      @primary_key {:id, Rice.Tsid.Type, autogenerate: true}
      @foreign_key_type Rice.Tsid.Type
      @timestamps_opts [type: :utc_datetime_usec]

      @type t :: %__MODULE__{}
    end
  end

  @doc "`update_change` 用:去首尾空白,nil 当空串。"
  @spec trim(term()) :: String.t()
  def trim(value) when is_binary(value), do: String.trim(value)
  def trim(_), do: ""

  @doc "`update_change` 用:去首尾空白,空串当 nil。"
  @spec optional_trim(term()) :: String.t() | nil
  def optional_trim(value) do
    case trim(value) do
      "" -> nil
      value -> value
    end
  end
end
