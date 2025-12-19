defmodule OLWSX.Actors.Codec do
  @moduledoc """
  کدک باینری برای ارتباط Edge ↔ Actors، سازگار با wire در Edge.
  """

  @type envelope :: %{
          path: binary(),
          method: binary(),
          headers_flat: binary(),
          body: binary() | nil,
          trace_id: non_neg_integer(),
          span_id: non_neg_integer(),
          edge_hints: non_neg_integer(),
          remote: binary() | nil
        }

  def decode_request(bin) when is_binary(bin) do
    try do
      <<method_len::32-little, method::binary-size(method_len),
        path_len::32-little, path::binary-size(path_len),
        headers_len::32-little, headers::binary-size(headers_len),
        body_len::32-little, body::binary-size(body_len),
        trace_id::64-little, span_id::64-little, hints::32-little>> = bin

      {:ok,
       %{
         path: path,
         method: method,
         headers_flat: headers,
         body: body,
         trace_id: trace_id,
         span_id: span_id,
         edge_hints: hints,
         remote: nil
       }}
    rescue
      _ -> {:error, :invalid_frame}
    end
  end

  def encode_response(%{status: st, headers_flat: hdr, body: body, meta_flags: flags})
      when is_integer(st) and is_binary(hdr) and (is_binary(body) or is_nil(body)) and is_integer(flags) do
    body = body || <<>>
    <<
      st::32-little,
      byte_size(hdr)::32-little, hdr::binary,
      byte_size(body)::32-little, body::binary,
      flags::32-little
    >>
  end
end