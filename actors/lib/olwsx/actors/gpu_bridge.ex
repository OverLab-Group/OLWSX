defmodule OLWSX.Actors.GPUBridge do
  @moduledoc """
  پل NIF به GPU (CUDA/OpenCL) برای محاسبات موازی در مسیرهای سنگین.
  """

  @on_load :load_nif

  def ensure_loaded, do: load_nif()

  def load_nif do
    path = System.get_env("OLWSX_GPU_NIF_PATH") || "priv/nif/gpu_bridge.so"
    case :erlang.load_nif(to_charlist(path), 0) do
      :ok -> :ok
      {:error, _} -> :ok
    end
  end

  # Run(task_name :: binary(), payload :: binary()) -> {:ok, binary()} | {:error, atom()}
  def run(task, payload) when is_binary(task) and is_binary(payload), do: run_nif(task, payload)

  defp run_nif(_t, _p), do: {:error, :nif_not_loaded}
end