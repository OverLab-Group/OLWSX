defmodule OLWSX.Actors.EventLoopWorker do
  @moduledoc """
  Worker ساده برای پردازش رویدادهای داخلی (می‌تواند برای آینده به epoll/kqueue وصل شود).
  """

  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, %{index: opts[:index], queue: :queue.new()}, name: via(opts[:index]))

  defp via(i), do: {:via, :erlang, {:olwsx_event_loop, i}}

  @impl true
  def init(state), do: {:ok, state}

  def enqueue(i, ev) do
    GenServer.cast(via(i), {:enqueue, ev})
  end

  @impl true
  def handle_cast({:enqueue, ev}, %{queue: q} = s) do
    q = :queue.in(ev, q)
    Process.send_after(self(), :drain, 0)
    {:noreply, %{s | queue: q}}
  end

  @impl true
  def handle_info(:drain, %{queue: q} = s) do
    case :queue.out(q) do
      {{:value, ev}, q2} ->
        handle_event(ev)
        Process.send_after(self(), :drain, 0)
        {:noreply, %{s | queue: q2}}
      {:empty, _} ->
        {:noreply, s}
    end
  end

  defp handle_event({:actor_submit, env}) do
    _ = OLWSX.Actors.Manager.submit(env)
    :ok
  end

  defp handle_event(_), do: :ok
end