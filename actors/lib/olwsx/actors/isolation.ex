defmodule OLWSX.Actors.Isolation do
  @moduledoc """
  ایزوله‌سازی و backpressure: صف جهانی با ETS، گارد اجرای ایزوله، و شمارنده‌ها.
  """

  use GenServer
  @table :olwsx_actor_q

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    :ets.new(@table, [:named_table, :public, read_concurrency: true])
    :ets.insert(@table, {:count, 0})
    {:ok, %{max: OLWSX.Actors.Config.queue_max()}}
  end

  def q_offer() do
    try do
      :ets.update_counter(@table, :count, {2, 1})
    catch
      _, _ -> :busy
    else
      c when is_integer(c) ->
        if c > OLWSX.Actors.Config.queue_max() do
          :ets.update_counter(@table, :count, {2, -1})
          :busy
        else
          :ok
        end
    end
  end

  def q_done() do
    try do
      :ets.update_counter(@table, :count, {2, -1})
      :ok
    catch
      _, _ -> :ok
    end
  end

  def guarded(fun) when is_function(fun, 0) do
    try do
      {:ok, fun.()}
    rescue
      _ -> {:error, :exception}
    catch
      _ -> {:error, :exception}
    end
  end

  def q_count do
    case :ets.lookup(@table, :count) do
      [{:count, c}] -> c
      _ -> 0
    end
  end
end