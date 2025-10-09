defmodule ElixirDnstap.FrameStreamsTest do
  use ExUnit.Case
  doctest ElixirDnstap.FrameStreams

  alias ElixirDnstap.FrameStreams

  @dnstap_content_type "protobuf:dnstap.Dnstap"

  describe "encode_data_frame/1" do
    test "encodes data frame with length prefix" do
      data = <<1, 2, 3, 4, 5>>
      expected_length = byte_size(data)

      frame = FrameStreams.encode_data_frame(data)

      # Frame should be: length (4 bytes big-endian) + data
      assert <<length::32-big, payload::binary>> = frame
      assert length == expected_length
      assert payload == data
    end

    test "handles empty data" do
      data = <<>>
      frame = FrameStreams.encode_data_frame(data)

      assert <<0::32-big, "">> = frame
    end

    test "handles large data" do
      data = :binary.copy(<<1>>, 10_000)
      frame = FrameStreams.encode_data_frame(data)

      assert <<10_000::32-big, ^data::binary>> = frame
    end
  end

  describe "encode_control_frame/2" do
    test "encodes START control frame with content type" do
      frame = FrameStreams.encode_control_frame(:start, @dnstap_content_type)

      # Should be: escape (0x00000000) + control_length + control_payload
      assert <<0::32-big, control_length::32-big, control_payload::binary>> = frame

      # Control payload should contain FSTRM_CONTROL_START and content type
      assert byte_size(control_payload) == control_length
      assert control_payload =~ @dnstap_content_type
    end

    test "encodes STOP control frame without content type" do
      frame = FrameStreams.encode_control_frame(:stop, nil)

      assert <<0::32-big, control_length::32-big, control_payload::binary>> = frame
      assert byte_size(control_payload) == control_length
      # STOP frame should not contain content type
      refute control_payload =~ @dnstap_content_type
    end

    test "encodes READY control frame with content type" do
      frame = FrameStreams.encode_control_frame(:ready, @dnstap_content_type)

      assert <<0::32-big, control_length::32-big, control_payload::binary>> = frame
      assert byte_size(control_payload) == control_length
      assert control_payload =~ @dnstap_content_type
    end

    test "encodes ACCEPT control frame with content type" do
      frame = FrameStreams.encode_control_frame(:accept, @dnstap_content_type)

      assert <<0::32-big, control_length::32-big, control_payload::binary>> = frame
      assert byte_size(control_payload) == control_length
      assert control_payload =~ @dnstap_content_type
    end

    test "encodes FINISH control frame without content type" do
      frame = FrameStreams.encode_control_frame(:finish, nil)

      assert <<0::32-big, control_length::32-big, control_payload::binary>> = frame
      assert byte_size(control_payload) == control_length
      refute control_payload =~ @dnstap_content_type
    end
  end

  describe "decode_frame/1" do
    test "decodes data frame" do
      data = <<1, 2, 3, 4, 5>>
      frame = FrameStreams.encode_data_frame(data)

      assert {:ok, {:data, ^data}, <<>>} = FrameStreams.decode_frame(frame)
    end

    test "decodes control frame (START)" do
      frame = FrameStreams.encode_control_frame(:start, @dnstap_content_type)

      assert {:ok, {:control, :start, content_type}, <<>>} = FrameStreams.decode_frame(frame)
      assert content_type == @dnstap_content_type
    end

    test "decodes control frame (STOP)" do
      frame = FrameStreams.encode_control_frame(:stop, nil)

      assert {:ok, {:control, :stop, nil}, <<>>} = FrameStreams.decode_frame(frame)
    end

    test "handles incomplete frame" do
      # Only 2 bytes instead of 4-byte length prefix
      incomplete = <<1, 2>>

      assert {:error, :incomplete} = FrameStreams.decode_frame(incomplete)
    end

    test "handles multiple frames in binary" do
      data1 = <<1, 2, 3>>
      data2 = <<4, 5, 6>>
      frame1 = FrameStreams.encode_data_frame(data1)
      frame2 = FrameStreams.encode_data_frame(data2)

      combined = frame1 <> frame2

      assert {:ok, {:data, ^data1}, rest} = FrameStreams.decode_frame(combined)
      assert {:ok, {:data, ^data2}, <<>>} = FrameStreams.decode_frame(rest)
    end
  end

  describe "uni-directional stream" do
    test "creates valid stream sequence" do
      # START frame
      start = FrameStreams.encode_control_frame(:start, @dnstap_content_type)

      # Data frames
      data1 = <<1, 2, 3>>
      data2 = <<4, 5, 6>>
      frame1 = FrameStreams.encode_data_frame(data1)
      frame2 = FrameStreams.encode_data_frame(data2)

      # STOP frame
      stop = FrameStreams.encode_control_frame(:stop, nil)

      stream = start <> frame1 <> frame2 <> stop

      # Decode and verify sequence
      assert {:ok, {:control, :start, @dnstap_content_type}, rest1} =
               FrameStreams.decode_frame(stream)

      assert {:ok, {:data, ^data1}, rest2} = FrameStreams.decode_frame(rest1)
      assert {:ok, {:data, ^data2}, rest3} = FrameStreams.decode_frame(rest2)
      assert {:ok, {:control, :stop, nil}, <<>>} = FrameStreams.decode_frame(rest3)
    end
  end

  describe "bi-directional stream handshake" do
    test "creates valid handshake sequence" do
      # Receiver sends READY
      ready = FrameStreams.encode_control_frame(:ready, @dnstap_content_type)

      assert {:ok, {:control, :ready, @dnstap_content_type}, <<>>} =
               FrameStreams.decode_frame(ready)

      # Sender responds with ACCEPT
      accept = FrameStreams.encode_control_frame(:accept, @dnstap_content_type)

      assert {:ok, {:control, :accept, @dnstap_content_type}, <<>>} =
               FrameStreams.decode_frame(accept)

      # Sender sends START
      start = FrameStreams.encode_control_frame(:start, @dnstap_content_type)

      assert {:ok, {:control, :start, @dnstap_content_type}, <<>>} =
               FrameStreams.decode_frame(start)

      # Data exchange...

      # Sender sends FINISH
      finish = FrameStreams.encode_control_frame(:finish, nil)
      assert {:ok, {:control, :finish, nil}, <<>>} = FrameStreams.decode_frame(finish)
    end
  end
end
