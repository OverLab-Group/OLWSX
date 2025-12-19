defmodule OLWSX.Actors.Router do
  @moduledoc """
  تصمیم‌گیری lane بر اساس method/path؛ نگاشت edge_hints به امنیت.
  """

  import Bitwise

  def security(edge_hints) when is_integer(edge_hints) do
    %{
      waf: (edge_hints &&& 0x2) != 0,
      ratelimit: (edge_hints &&& 0x1) != 0,
      challenged: (edge_hints &&& 0x4) != 0
    }
  end

  def pick_lane(%{path: path, method: method}) do
    cond do
      String.starts_with?(path, "/static/") -> {:cache, :l2}
      method in ["POST", "PUT", "PATCH"] -> {:core, :write}
      true -> {:core, :read}
    end
  end
end