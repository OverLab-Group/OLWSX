defmodule OLWSX.Actors.Config do
  import Bitwise
  @moduledoc """
  تنظیمات قطعی Actors با امکان override از env.
  """

  @default_socket "/run/olwsx/actor_manager.sock"
  @default_timeout_ms 2000
  @default_retry_max 1
  @default_queue_max 10000000 # برای DDoS مقیاس کیهانی
  @default_frame_max 1 <<< 20 # 1MB
  @default_event_loops 4
  @default_gpu_enabled true

  def actor_socket_path, do: env_str("OLWSX_ACTOR_SOCKET", @default_socket)
  def default_timeout_ms, do: env_int("OLWSX_ACTOR_TIMEOUT_MS", @default_timeout_ms)
  def default_retry_max, do: env_int("OLWSX_ACTOR_RETRY_MAX", @default_retry_max)
  def queue_max, do: env_int("OLWSX_ACTOR_QUEUE_MAX", @default_queue_max)
  def frame_max_bytes, do: env_int("OLWSX_ACTOR_FRAME_MAX", @default_frame_max)
  def event_loops, do: env_int("OLWSX_EVENT_LOOPS", @default_event_loops)
  def gpu_enabled?, do: env_bool("OLWSX_GPU_ENABLED", @default_gpu_enabled)

  defp env_str(k, d), do: System.get_env(k) || d

  defp env_int(k, d) do
    case System.get_env(k) do
      nil -> d
      s ->
        case Integer.parse(s) do
          {v, _} -> v
          _ -> d
        end
    end
  end

  defp env_bool(k, d) do
    case System.get_env(k) do
      nil -> d
      "1" -> true
      "true" -> true
      "TRUE" -> true
      _ -> false
    end
  end
end