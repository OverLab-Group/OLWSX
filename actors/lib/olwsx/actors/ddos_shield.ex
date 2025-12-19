defmodule OLWSX.Actors.DDoSShield do
  @moduledoc """
  DDoS Shield داخلی: token-bucket per-IP، در مسیر Actor لیول.
  """

  use GenServer
  @bucket_capacity 100
  @refill_per_sec 50

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  @impl true
  def init(state), do: {:ok, state}

  def check(remote), do: GenServer.call(__MODULE__, {:check, remote})

  @impl true
  def handle_call({:check, remote}, _from, state) do
    now = System.system_time(:second)
    b = Map.get(state, remote, %{tokens: @bucket_capacity, last: now})
    elapsed = now - b.last
    tokens = min(@bucket_capacity, b.tokens + elapsed * @refill_per_sec)
    if tokens > 0 do
      b = %{tokens: tokens - 1, last: now}
      {:reply, :ok, Map.put(state, remote, b)}
    else
      {:reply, :limited, state}
    end
  end
end