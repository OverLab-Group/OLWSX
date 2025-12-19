defmodule OLWSX.Actors.GPUWorker do
  @moduledoc """
  GPU Worker GenServer: اجرای تسک‌های GPU به‌صورت synchronous درخواست‌محور.
  """

  use GenServer

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{enabled: OLWSX.Actors.Config.gpu_enabled?()}, name: __MODULE__)

  @impl true
  def init(state), do: {:ok, state}

  def compute(task, payload) do
    GenServer.call(__MODULE__, {:compute, task, payload}, 30_000)
  end

  @impl true
  def handle_call({:compute, task, payload}, _from, %{enabled: false} = s), do: {:reply, {:error, :gpu_disabled}, s}

  @impl true
  def handle_call({:compute, task, payload}, _from, s) do
    case OLWSX.Actors.GPUBridge.run(task, payload) do
      {:ok, result} -> {:reply, {:ok, result}, s}
      {:error, reason} -> {:reply, {:error, reason}, s}
    end
  end
end