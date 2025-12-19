defmodule OLWSX.Actors.CoreNIF do
  @moduledoc """
  پل NIF به Core (`olwsx_core_nif.so` → `olwsx_core.so`).
  """

  @on_load :load_nif

  def ensure_loaded, do: load_nif()

  def load_nif do
    path = System.get_env("OLWSX_CORE_NIF_PATH") || "priv/nif/olwsx_core_nif.so"
    case :erlang.load_nif(to_charlist(path), 0) do
      :ok -> :ok
      {:error, _} -> :ok
    end
  end

  def core_init(), do: core_init_nif()
  def core_shutdown(), do: core_shutdown_nif()
  def core_status(), do: core_status_nif()
  def arena_reset(), do: arena_reset_nif()

  def stage_config(blob, gen) when is_binary(blob) and is_integer(gen), do: stage_config_nif(blob, gen)
  def apply_config(gen) when is_integer(gen), do: apply_config_nif(gen)

  def process_request(env) when is_map(env) do
    path = env[:path] || env["path"]
    method = env[:method] || env["method"]
    headers = env[:headers_flat] || env["headers_flat"]
    body = env[:body] || <<>>
    trace_id = env[:trace_id] || 0
    span_id = env[:span_id] || 0
    hints = env[:edge_hints] || 0
    process_request_nif(path, method, headers, body, trace_id, span_id, hints)
  end

  defp core_init_nif(), do: {:error, :nif_not_loaded}
  defp core_shutdown_nif(), do: {:error, :nif_not_loaded}
  defp core_status_nif(), do: {:error, :nif_not_loaded}
  defp arena_reset_nif(), do: {:error, :nif_not_loaded}
  defp stage_config_nif(_blob, _gen), do: {:error, :nif_not_loaded}
  defp apply_config_nif(_gen), do: {:error, :nif_not_loaded}
  defp process_request_nif(_p, _m, _h, _b, _t, _s, _hints), do: {:error, :nif_not_loaded}
end