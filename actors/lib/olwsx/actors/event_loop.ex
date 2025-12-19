defmodule OLWSX.Actors.EventLoop do
  @moduledoc """
  Event Loop multiplexer: چند حلقه‌ی پذیرش رویداد برای تقسیم بار Listenerها.
  """

  use Supervisor

  def start_link(_opts), do: Supervisor.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    loops = OLWSX.Actors.Config.event_loops()
    children =
      for i <- 1..loops do
        %{
          id: {:olwsx_event_loop_worker, i},
          start: {OLWSX.Actors.EventLoopWorker, :start_link, [[index: i]]},
          type: :worker,
          restart: :permanent,
          shutdown: 5000
        }
      end

    Supervisor.init(children, strategy: :one_for_one)
  end
end