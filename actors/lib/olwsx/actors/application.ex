defmodule OLWSX.Actors.Application do
  @moduledoc """
  Entry point: بارگذاری NIFها، راه‌اندازی سوپرویژن، event loops، listenerها، و شیلد DDoS.
  """

  use Application

  def start(_type, _args) do
    # Load NIF bridges (Core and GPU)
    _ = OLWSX.Actors.CoreNIF.ensure_loaded()
    _ = OLWSX.Actors.GPUBridge.ensure_loaded()

    socket_path = OLWSX.Actors.Config.actor_socket_path()

    children = [
      # Backpressure + global queue
      {OLWSX.Actors.Isolation, []},
      # DDoS shield (per-IP token bucket)
      {OLWSX.Actors.DDoSShield, []},
      # Event loop multiplexer (non-blocking accept)
      {OLWSX.Actors.EventLoop, []},
      # Actor pools (GPU/IO-bound workers registration surface)
      {OLWSX.Actors.ActorPool, []},
      # DynamicSupervisor for per-request actors
      {OLWSX.Actors.Supervisor, []},
      # Socket listener for Edge ↔ Actors (Unix domain socket)
      {OLWSX.Actors.Listener, socket_path}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: OLWSX.Actors.AppSupervisor)
  end
end