defmodule Rice.Admin.LoginAttempt do
  @moduledoc """
  管理端登录第一步的密码试错计数。

  ## 为什么按手机号记,不按管理员

  `POST /session/challenge` 密码对了 202、错了 401 —— 这是一个可以无限次问的
  "这个密码对不对"。而整套设计刻意不让人区分"密码错"和"账号不存在"。

  如果按管理员 id 计数,不存在的手机号就永远不会被锁:试第六次还返回 401 而不是
  429,等于告诉攻击者"这个号不是管理员"。所以键是手机号本身,**存不存在都记**。

  ## 锁多久,以及它的代价

  连错 5 次锁 15 分钟。密码一旦对上就立刻清零。

  代价是明摆着的:知道某个管理员手机号的人,连错 5 次就能把他挡在门外 15 分钟。
  这是账号锁定这类方案共有的问题。选 15 分钟而不是永久锁,是因为永久锁意味着
  任何人都能让一个管理员**永远**登不进去,那比暴力破解更糟。

  真要把这个代价也去掉,得按 IP 之类的调用方维度限流,或者上工作量证明 ——
  两者都需要一个这里还没有的基础设施。
  """
  use Ecto.Schema

  import Ecto.Changeset

  @max_attempts 5
  @lock_minutes 15

  @primary_key false
  @type t :: %__MODULE__{}

  schema "admin_login_attempts" do
    field :phone_region, :string
    field :phone, :string
    field :attempts, :integer, default: 0
    field :locked_until, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(record, attrs) do
    record
    |> cast(attrs, [:phone_region, :phone, :attempts, :locked_until])
    |> validate_required([:phone_region, :phone])
  end

  @doc "现在还锁着吗。"
  @spec locked?(t() | nil, DateTime.t()) :: boolean()
  def locked?(nil, _now), do: false

  def locked?(%__MODULE__{locked_until: nil}, _now), do: false

  def locked?(%__MODULE__{locked_until: until}, now),
    do: DateTime.compare(until, now) == :gt

  @spec max_attempts() :: pos_integer()
  def max_attempts, do: @max_attempts
  @spec lock_minutes() :: pos_integer()
  def lock_minutes, do: @lock_minutes
end
