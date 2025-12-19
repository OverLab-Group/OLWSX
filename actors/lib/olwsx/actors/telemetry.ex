defmodule OLWSX.Actors.Telemetry do
  @moduledoc """
  Telemetry داخلی برای شمارنده‌ها و latency؛ نام‌گذاری پایدار.
  """

  def emit(event, measurements \\ %{}, metadata \\ %{}) do
    :telemetry.execute([:olwsx, :actors, event], measurements, metadata)
  end

  def inc(name, meta \\ %{}) do
    emit(:counter, %{count: 1}, Map.put(meta, :name, name))
  end

  def add(name, n, meta \\ %{}) do
    emit(:counter, %{count: n}, Map.put(meta, :name, name))
  end

  def latency(name, dur_ms, meta \\ %{}) do
    emit(:latency, %{duration: dur_ms}, Map.put(meta, :name, name))
  end
end