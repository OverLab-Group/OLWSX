defmodule OLWSX.Security.Isolation do
  @moduledoc false

  @window_ms 10_000
  @fail_threshold 5
  @timeout_threshold 3
  @quarantine_ms 30_000

  defstruct failures: 0, timeouts: 0, window_start_ms: now_ms(), quarantined_until_ms: 0

  @type state :: %__MODULE__{
          failures: non_neg_integer(),
          timeouts: non_neg_integer(),
          window_start_ms: non_neg_integer(),
          quarantined_until_ms: non_neg_integer()
        }

  @spec new() :: state
  def new(), do: %__MODULE__{}

  @spec record_failure(state) :: state
  def record_failure(%__MODULE__{} = s) do
    rotate_window(s)
    %{s | failures: s.failures + 1}
    |> maybe_quarantine()
  end

  @spec record_timeout(state) :: state
  def record_timeout(%__MODULE__{} = s) do
    rotate_window(s)
    %{s | timeouts: s.timeouts + 1}
    |> maybe_quarantine()
  end

  @spec allowed?(state) :: boolean
  def allowed?(%__MODULE__{} = s) do
    now_ms() >= s.quarantined_until_ms
  end

  @spec backpressure_signal(state) :: :ok | {:shed, :compression | :gpu | :inference}
  def backpressure_signal(%__MODULE__{} = s) do
    cond do
      s.failures >= @fail_threshold and s.timeouts >= @timeout_threshold ->
        {:shed, :gpu}
      s.timeouts >= @timeout_threshold ->
        {:shed, :compression}
      s.failures >= @fail_threshold ->
        {:shed, :inference}
      true ->
        :ok
    end
  end

  defp rotate_window(%__MODULE__{} = s) do
    if now_ms() - s.window_start_ms > @window_ms do
      %{s | failures: 0, timeouts: 0, window_start_ms: now_ms()}
    else
      s
    end
  end

  defp maybe_quarantine(%__MODULE__{} = s) do
    if s.failures >= @fail_threshold or s.timeouts >= @timeout_threshold do
      %{s | quarantined_until_ms: now_ms() + @quarantine_ms}
    else
      s
    end
  end

  defp now_ms(), do: System.os_time(:millisecond)
end

# Example integration with an actor process:
defmodule OLWSX.ActorGuard do
  alias OLWSX.Security.Isolation, as: Iso

  def run_work(ctx) do
    state = Map.get(ctx, :iso_state, Iso.new())

    if Iso.allowed?(state) do
      # do work...
      case do_work() do
        :ok ->
          next = state
        {:error, :timeout} ->
          next = Iso.record_timeout(state)
        {:error, _} ->
          next = Iso.record_failure(state)
      end

      case Iso.backpressure_signal(next) do
        {:shed, what} -> send(self(), {:shed, what})
        :ok -> :noop
      end

      Map.put(ctx, :iso_state, next)
    else
      {:quarantined, state}
    end
  end

  defp do_work(), do: :ok
end