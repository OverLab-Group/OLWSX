defmodule OLWSX.Actors.Workflow do
  @moduledoc false
  use GenServer

  alias OLWSX.Actors.Router
  alias OLWSX.Actors.Isolation
  alias OLWSX.Actors.CoreNIF
  alias OLWSX.Actors.Telemetry

  def start_link(%{envelope: env, timeout_ms: tms, retry_max: rmax}) do
    GenServer.start_link(__MODULE__, %{envelope: env, timeout_ms: tms, retry_left: rmax, parent: nil})
  end

  @impl true
  def init(state) do
    Process.flag(:trap_exit, true)
    {:ok, state}
  end

  @impl true
  def handle_info({:begin, parent}, state) do
    state = %{state | parent: parent}
    case step_run(state.envelope, state.timeout_ms) do
      {:ok, resp} ->
        send(parent, {:actor_result, self(), {:ok, resp}})
        {:stop, :normal, state}
      {:error, :timeout} ->
        if state.retry_left > 0 do
          Process.send_after(self(), :retry, 0)
          {:noreply, %{state | retry_left: state.retry_left - 1}}
        else
          send(parent, {:actor_result, self(), {:error, :timeout}})
          {:stop, :normal, state}
        end
      {:error, :core_error} ->
        if state.retry_left > 0 do
          Process.send_after(self(), :retry, 0)
          {:noreply, %{state | retry_left: state.retry_left - 1}}
        else
          send(parent, {:actor_result, self(), {:error, :actor_crash}})
          {:stop, :normal, state}
        end
      {:error, :invalid} ->
        send(parent, {:actor_result, self(), {:error, :invalid_envelope}})
        {:stop, :normal, state}
    end
  end

  @impl true
  def handle_info(:retry, state) do
    case step_run(state.envelope, state.timeout_ms) do
      {:ok, resp} ->
        send(state.parent, {:actor_result, self(), {:ok, resp}})
        {:stop, :normal, state}
      {:error, :timeout} ->
        send(state.parent, {:actor_result, self(), {:error, :timeout}})
        {:stop, :normal, state}
      {:error, _} ->
        send(state.parent, {:actor_result, self(), {:error, :actor_crash}})
        {:stop, :normal, state}
    end
  end

  @impl true
  def terminate(_reason, _state), do: :ok

  defp step_run(env, _timeout_ms) do
    ts0 = System.monotonic_time(:millisecond)
    with true <- valid_env?(env) || {:error, :invalid},
         {:ok, sec} <- Isolation.guarded(fn -> Router.security(env.edge_hints) end),
         {:ok, lane} <- Isolation.guarded(fn -> Router.pick_lane(env) end),
         {:ok, resp} <- core_call(env, sec, lane) do
      Telemetry.latency(:actor_ok, System.monotonic_time(:millisecond) - ts0, %{trace_id: env.trace_id})
      {:ok, resp}
    else
      {:error, reason} ->
        Telemetry.latency(:actor_err, System.monotonic_time(:millisecond) - ts0, %{reason: reason, trace_id: env.trace_id})
        {:error, reason}
      false ->
        {:error, :invalid}
    end
  end

  defp valid_env?(%{path: p, method: m, headers_flat: h, body: b, trace_id: t, span_id: s, edge_hints: e}),
    do: is_binary(p) and is_binary(m) and is_binary(h) and (is_binary(b) or is_nil(b)) and is_integer(t) and is_integer(s) and is_integer(e)

  defp core_call(env, sec, lane) do
    Telemetry.emit(:workflow_lane, %{}, %{lane: lane, trace_id: env.trace_id})

    cond do
      sec.waf ->
        {:ok, %{status: 403, headers_flat: "Content-Type: text/plain\r\n", body: "Forbidden (WAF)", meta_flags: 0x00200000}}
      sec.ratelimit ->
        {:ok, %{status: 429, headers_flat: "Content-Type: text/plain\r\nRetry-After: 1\r\n", body: "Too Many Requests (Rate Limit)", meta_flags: 0x00400000}}
      true ->
        case CoreNIF.process_request(env) do
          {:ok, resp} -> {:ok, resp}
          {:error, _} -> {:error, :core_error}
        end
    end
  end
end