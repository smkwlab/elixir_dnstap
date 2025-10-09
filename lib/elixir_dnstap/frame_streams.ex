defmodule ElixirDnstap.FrameStreams do
  @moduledoc """
  Frame Streams protocol implementation for dnstap.

  Frame Streams is a lightweight framing protocol for transporting data.
  This module implements the Frame Streams specification for use with dnstap.

  ## Protocol Overview

  - **Data frames**: `<<length::32-big, data::binary>>`
  - **Control frames**: `<<0::32-big, control_length::32-big, control_payload::binary>>`

  ## Frame Types

  ### Data Frame
  A data frame consists of a 4-byte big-endian length field followed by the payload.

  ### Control Frame
  A control frame starts with an escape sequence (length = 0), followed by the
  control frame length and payload.

  Control frame types:
  - `START` - Begin stream, includes content type
  - `STOP` - End stream
  - `READY` - (Bi-directional) Receiver ready
  - `ACCEPT` - (Bi-directional) Sender accepts
  - `FINISH` - (Bi-directional) Stream finished

  ## Usage

  ### Uni-directional Stream

      # Sender
      start = FrameStreams.encode_control_frame(:start, "protobuf:dnstap.Dnstap")
      data1 = FrameStreams.encode_data_frame(dnstap_message1)
      data2 = FrameStreams.encode_data_frame(dnstap_message2)
      stop = FrameStreams.encode_control_frame(:stop, nil)

  ### Bi-directional Stream

      # Receiver sends READY
      ready = FrameStreams.encode_control_frame(:ready, "protobuf:dnstap.Dnstap")

      # Sender responds with ACCEPT and START
      accept = FrameStreams.encode_control_frame(:accept, "protobuf:dnstap.Dnstap")
      start = FrameStreams.encode_control_frame(:start, "protobuf:dnstap.Dnstap")

      # Data exchange...

      # Sender sends FINISH
      finish = FrameStreams.encode_control_frame(:finish, nil)
  """

  # Frame Streams control frame types (32-bit big-endian)
  @fstrm_control_accept 0x01
  @fstrm_control_start 0x02
  @fstrm_control_stop 0x03
  @fstrm_control_ready 0x04
  @fstrm_control_finish 0x05

  # Frame Streams control field types
  @fstrm_control_field_content_type 0x01

  @typedoc """
  Frame Streams control frame types.
  """
  @type frame_type :: :accept | :start | :stop | :ready | :finish

  @doc """
  Encode a data frame.

  ## Parameters

  - `data` - Binary data payload (typically a dnstap Protocol Buffer message)

  ## Returns

  Encoded data frame as binary: `<<length::32-big, data::binary>>`

  ## Examples

      iex> ElixirDnstap.FrameStreams.encode_data_frame(<<1, 2, 3>>)
      <<0, 0, 0, 3, 1, 2, 3>>
  """
  @spec encode_data_frame(binary()) :: binary()
  def encode_data_frame(data) when is_binary(data) do
    length = byte_size(data)
    <<length::32-big, data::binary>>
  end

  @doc """
  Encode a control frame.

  ## Parameters

  - `type` - Control frame type (`:start`, `:stop`, `:ready`, `:accept`, `:finish`)
  - `content_type` - Content type string (e.g., "protobuf:dnstap.Dnstap") or `nil`

  ## Returns

  Encoded control frame as binary

  ## Examples

      iex> frame = ElixirDnstap.FrameStreams.encode_control_frame(:start, "protobuf:dnstap.Dnstap")
      iex> <<0::32, _::binary>> = frame
      iex> :ok
      :ok
  """
  @spec encode_control_frame(frame_type(), binary() | nil) :: binary()
  def encode_control_frame(type, content_type) do
    control_type = control_type_to_int(type)
    control_payload = encode_control_payload(control_type, content_type)
    control_length = byte_size(control_payload)

    # Escape sequence (0x00000000) + control frame length + control payload
    <<0::32-big, control_length::32-big, control_payload::binary>>
  end

  @doc """
  Decode a frame from binary data.

  ## Parameters

  - `binary` - Binary data containing one or more frames

  ## Returns

  - `{:ok, frame, rest}` - Successfully decoded frame and remaining binary
  - `{:error, :incomplete}` - Incomplete frame data

  Where `frame` is one of:
  - `{:data, payload}` - Data frame with payload
  - `{:control, type, content_type}` - Control frame with type and optional content type

  ## Examples

      iex> data_frame = ElixirDnstap.FrameStreams.encode_data_frame(<<1, 2, 3>>)
      iex> {:ok, {:data, <<1, 2, 3>>}, <<>>} = ElixirDnstap.FrameStreams.decode_frame(data_frame)
  """
  @spec decode_frame(binary()) ::
          {:ok, {:data, binary()} | {:control, atom(), String.t() | nil}, binary()}
          | {:error, :incomplete}
  def decode_frame(binary) when byte_size(binary) < 4 do
    {:error, :incomplete}
  end

  def decode_frame(<<0::32-big, rest::binary>>) do
    # Control frame (escape sequence detected)
    decode_control_frame(rest)
  end

  def decode_frame(<<length::32-big, rest::binary>>) when byte_size(rest) >= length do
    # Data frame
    <<payload::binary-size(length), remaining::binary>> = rest
    {:ok, {:data, payload}, remaining}
  end

  def decode_frame(_binary) do
    {:error, :incomplete}
  end

  # Private functions

  defp control_type_to_int(:accept), do: @fstrm_control_accept
  defp control_type_to_int(:start), do: @fstrm_control_start
  defp control_type_to_int(:stop), do: @fstrm_control_stop
  defp control_type_to_int(:ready), do: @fstrm_control_ready
  defp control_type_to_int(:finish), do: @fstrm_control_finish

  defp int_to_control_type(@fstrm_control_accept), do: :accept
  defp int_to_control_type(@fstrm_control_start), do: :start
  defp int_to_control_type(@fstrm_control_stop), do: :stop
  defp int_to_control_type(@fstrm_control_ready), do: :ready
  defp int_to_control_type(@fstrm_control_finish), do: :finish

  defp encode_control_payload(control_type, nil) do
    # Control frame without content type
    <<control_type::32-big>>
  end

  defp encode_control_payload(control_type, content_type) when is_binary(content_type) do
    # Control frame with content type field
    content_type_length = byte_size(content_type)

    <<control_type::32-big, @fstrm_control_field_content_type::32-big,
      content_type_length::32-big, content_type::binary>>
  end

  defp decode_control_frame(binary) when byte_size(binary) < 4 do
    {:error, :incomplete}
  end

  defp decode_control_frame(<<control_length::32-big, rest::binary>>)
       when byte_size(rest) >= control_length do
    <<control_payload::binary-size(control_length), remaining::binary>> = rest

    case decode_control_payload(control_payload) do
      {:ok, type, content_type} ->
        {:ok, {:control, type, content_type}, remaining}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decode_control_frame(_binary) do
    {:error, :incomplete}
  end

  defp decode_control_payload(<<control_type::32-big, rest::binary>>) do
    type = int_to_control_type(control_type)
    content_type = decode_content_type_field(rest)

    {:ok, type, content_type}
  rescue
    _ ->
      {:error, :invalid_control_frame}
  end

  defp decode_content_type_field(<<>>) do
    nil
  end

  defp decode_content_type_field(
         <<@fstrm_control_field_content_type::32-big, length::32-big, rest::binary>>
       )
       when byte_size(rest) >= length do
    <<content_type::binary-size(length), _::binary>> = rest
    content_type
  end

  defp decode_content_type_field(_) do
    # Unknown or unsupported control field, ignore
    nil
  end
end
