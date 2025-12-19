defmodule OLWSX.Actors.Listener do
  @moduledoc """
  یونیکس‌سوکت لیسنر: دریافت envelope از Edge، DDoS check، backpressure، submit، و encode پاسخ.
  """

  use GenServer
  alias OLWSX.Actors.{Codec, Manager, Telemetry, DDoSShield, Isolation}

  def start_link(path) when is_binary(path), do: GenServer.start_link(__MODULE__, path, name: __MODULE__)

  @impl true
  def init(path) do
    _ = File.rm(path)
    :ok = File.mkdir_p(Path.dirname(path))
    {:ok, lsock} = :socket.open(:local, :stream, :default)
    :ok = :socket.bind(lsock, %{family: :local, path: path})
    :ok = :socket.listen(lsock, 1024)
    send(self(), :accept_loop)
    {:ok, %{path: path, lsock: lsock}}
  end

  @impl true
  def handle_info(:accept_loop, state) do
    case :socket.accept(state.lsock, 200) do
      {:ok, csock} ->
        spawn_link(fn -> handle_client(csock) end)
      {:error, :timeout} -> :ok
      {:error, _} -> :ok
    end
    send(self(), :accept_loop)
    {:noreply, state}
  end

  defp handle_client(csock) do
    max_bytes = OLWSX.Actors.Config.frame_max_bytes()
    case recv_all(csock, max_bytes, 3000) do
      {:ok, bin} ->
        case Codec.decode_request(bin) do
          {:ok, env} ->
            remote = extract_remote(csock)
            case DDoSShield.check(remote) do
              :ok ->
                env = Map.put(env, :remote, remote)
                case Manager.submit(env) do
                  {:ok, resp} ->
                    frame = Codec.encode_response(resp)
                    _ = :socket.send(csock, frame)
                    Telemetry.inc(:listener_ok)
                  {:error, reason} ->
                    frame = Codec.encode_response(%{
                      status: 502,
                      headers_flat: "Content-Type: text/plain\r\n",
                      body: "Actor error: " <> to_string(reason),
                      meta_flags: 0x00000010
                    })
                    _ = :socket.send(csock, frame)
                    Telemetry.inc(:listener_actor_error, %{reason: reason})
                end
              :limited ->
                frame = Codec.encode_response(%{
                  status: 429,
                  headers_flat: "Content-Type: text/plain\r\nRetry-After: 1\r\n",
                  body: "Rate Limit (Actor Shield)",
                  meta_flags: 0x00400000
                })
                _ = :socket.send(csock, frame)
                Telemetry.inc(:listener_rate_limited)
            end
          {:error, :invalid_frame} ->
            frame = Codec.encode_response(%{
              status: 400,
              headers_flat: "Content-Type: text/plain\r\n",
              body: "Invalid frame",
              meta_flags: 0x00000020
            })
            _ = :socket.send(csock, frame)
            Telemetry.inc(:listener_bad_frame)
        end
      {:error, reason} ->
        Telemetry.inc(:listener_read_error, %{reason: reason})
    end
    _ = :socket.close(csock)
  end

  defp recv_all(sock, max_bytes, timeout_ms) do
    :socket.setopt(sock, :tcp, :recvtimeout, timeout_ms)
    case :socket.recv(sock, max_bytes, timeout_ms) do
      {:ok, data} -> {:ok, data}
      {:error, reason} -> {:error, reason}
    end
  end

  defp extract_remote(_sock), do: "unix" # برای UDS، remote مفهومی ندارد؛ پلاسبو
end