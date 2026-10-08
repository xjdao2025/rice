defmodule Rice.RateLimit do
  @moduledoc """
  进程内的固定窗口计数,给没有落库记录可数的接口用(比如按手机号查收款人)。

  rice 是单实例部署,计数放 ETS 就够;重启清零也无妨 —— 它挡的是脚本批量调用,
  不是精确配额。按用户计,不按 IP:rice-front 从自己的服务端调 rice,前面还有
  代理,rice 看到的来源 IP 几乎都是同一个。
  """
  use GenServer

  @table __MODULE__

  @spec start_link(term()) :: GenServer.on_start()
  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "`window` 秒内的第 `limit` 次以内返回 `:ok`,超过返回 `{:error, :too_many_requests}`。"
  @spec hit(term(), pos_integer(), pos_integer()) :: :ok | {:error, :too_many_requests}
  def hit(key, limit, window) do
    now = System.system_time(:second)
    bucket = {key, div(now, window)}

    if :ets.update_counter(@table, bucket, {2, 1}, {bucket, 0, now + window}) <= limit,
      do: :ok,
      else: {:error, :too_many_requests}
  end

  @impl true
  def init(nil) do
    :ets.new(@table, [:named_table, :public, write_concurrency: true])
    :timer.send_interval(:timer.minutes(5), :sweep)
    {:ok, nil}
  end

  @impl true
  def handle_info(:sweep, state) do
    now = System.system_time(:second)
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:<, :"$1", now}], [true]}])
    {:noreply, state}
  end
end
