defmodule OLWSX.Actors.ActorPool do
  @moduledoc """
  Pool برای کارهای سنگین (GPU/IO-bound). Round-robin ساده؛ قابل ارتقا به EWMA/latency-aware.
  """

  use GenServer
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts), do: {:ok, %{workers: [], index: 0}}

  def register(pid), do: GenServer.cast(__MODULE__, {:register, pid})
  def pick(), do: GenServer.call(__MODULE__, :pick)

  @impl true
  def handle_cast({:register, pid}, s), do: {:noreply, %{s | workers: s.workers ++ [pid]}}
  @impl true
  def handle_call(:pick, _from, %{workers: []} = s), do: {:reply, {:error, :no_workers}, s}
  def handle_call(:pick, _from, s) do
    idx = rem(s.index, length(s.workers))
    {:reply, {:ok, Enum.at(s.workers, idx)}, %{s | index: s.index + 1}}
  end
end