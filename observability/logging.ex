# =============================================================================
# OLWSX - OverLab Web ServerX
# File: observability/logging.ex
# Role: Final & Stable structured logging with actor-aware context
# Philosophy: One version, the most stable version, first and last.
# -----------------------------------------------------------------------------
# Responsibilities:
# - JSON logs with fixed schema: ts, lvl, msg, actor_id, trace_id, span_id, kv.
# - Process dictionary carries correlation IDs within actor processes.
# - Helpers: log_debug/info/warn/error with constant-time formatting.
# =============================================================================

defmodule OLWSX.Logging do
  @moduledoc false

  @levels %{debug: 10, info: 20, warn: 30, error: 40}
  @spec set_ctx(trace_id :: integer, span_id :: integer, actor_id :: integer) :: :ok
  def set_ctx(trace_id, span_id, actor_id) do
    Process.put(:olwsx_trace_id, trace_id)
    Process.put(:olwsx_span_id, span_id)
    Process.put(:olwsx_actor_id, actor_id)
    :ok
  end

  @spec get_ctx() :: {integer | nil, integer | nil, integer | nil}
  def get_ctx() do
    {Process.get(:olwsx_trace_id), Process.get(:olwsx_span_id), Process.get(:olwsx_actor_id)}
  end

  def log_debug(msg, kv \\ %{}), do: emit(:debug, msg, kv)
  def log_info(msg, kv \\ %{}),  do: emit(:info, msg, kv)
  def log_warn(msg, kv \\ %{}),  do: emit(:warn, msg, kv)
  def log_error(msg, kv \\ %{}), do: emit(:error, msg, kv)

  defp emit(level, msg, kv) when is_map(kv) do
    {trace_id, span_id, actor_id} = get_ctx()
    entry = %{
      ts_ms: now_ms(),
      lvl: Map.fetch!(@levels, level),
      msg: to_string(msg),
      trace_id: trace_id,
      span_id: span_id,
      actor_id: actor_id,
      kv: stringify_map(kv)
    }
    IO.binwrite(:stdio, Jason.encode!(entry) <> "\n")
    :ok
  end

  defp stringify_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), to_string(v)}
      {k, v} -> {to_string(k), to_string(v)}
    end)
  end

  defp now_ms() do
    System.os_time(:millisecond)
  end
end

# Example usage (in an actor process)
defmodule OLWSX.ActorExample do
  def run() do
    OLWSX.Logging.set_ctx(0x01, 0x02, 0x2A)
    OLWSX.Logging.log_info("actor started", %{route: "/hello", method: "GET"})
    # ... work ...
    OLWSX.Logging.log_warn("slow response", %{latency_ms: 212})
    OLWSX.Logging.log_error("upstream failed", %{code: 502})
  end
end