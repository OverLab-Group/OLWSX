defmodule OLWSX.Actors.Manager do
  @moduledoc """
  API عمومی برای submit envelope با backpressure, timeout, retry.
  """

  alias OLWSX.Actors.Supervisor, as: ActorSupervisor
  alias OLWSX.Actors.Workflow
  alias OLWSX.Actors.Isolation
  alias OLWSX.Actors.Telemetry

  @spec submit(map(), keyword()) :: {:ok, map()} | {:error, atom()}
  def submit(env, opts \\ []) do
    timeout_ms = Keyword.get(opts, :timeout_ms, OLWSX.Actors.Config.default_timeout_ms())
    retry_max  = Keyword.get(opts, :retry_max,  OLWSX.Actors.Config.default_retry_max())

    case Isolation.q_offer() do
      :busy ->
        Telemetry.inc(:busy, %{trace_id: env[:trace_id]})
        {:error, :busy}

      :ok ->
        spec = {Workflow, %{envelope: env, timeout_ms: timeout_ms, retry_max: retry_max}}
        case DynamicSupervisor.start_child(ActorSupervisor, spec) do
          {:ok, pid} ->
            ref = Process.monitor(pid)
            send(pid, {:begin, self()})
            receive do
              {:actor_result, ^pid, {:ok, result}} ->
                Process.demonitor(ref, [:flush])
                Isolation.q_done()
                {:ok, result}
              {:actor_result, ^pid, {:error, reason}} ->
                Process.demonitor(ref, [:flush])
                Isolation.q_done()
                {:error, reason}
              {:DOWN, ^ref, :process, ^pid, _reason} ->
                Isolation.q_done()
                {:error, :actor_crash}
            after
              timeout_ms ->
                Isolation.q_done()
                send(pid, :cancel)
                {:error, :timeout}
            end
          {:error, _} ->
            Isolation.q_done()
            {:error, :actor_crash}
        end
    end
  end
end