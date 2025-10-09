defmodule ElixirDnstap.WriterConsumerTest do
  use ExUnit.Case, async: false

  alias ElixirDnstap.Encoder
  alias ElixirDnstap.FrameStreams
  alias ElixirDnstap.Writer.File
  alias ElixirDnstap.WriterConsumer

  @test_dir "/tmp/tenbin_cache_test/writer_consumer"

  setup do
    # Clean up test directory
    File.rm_rf!(@test_dir)
    File.mkdir_p!(@test_dir)

    on_exit(fn ->
      File.rm_rf!(@test_dir)
    end)

    :ok
  end

  describe "init/1" do
    test "initializes with FileWriter module" do
      file_path = Path.join(@test_dir, "test.fstrm")
      {:ok, _writer_pid} = FileWriter.start_link(path: file_path)

      assert {:consumer, state, _} = WriterConsumer.init(writer_module: FileWriter)
      assert state.writer_module == FileWriter
    end
  end

  describe "handle_events/3 - writing frames" do
    setup do
      file_path = Path.join(@test_dir, "events.fstrm")
      {:ok, _writer_pid} = FileWriter.start_link(path: file_path)

      %{file_path: file_path}
    end

    test "writes single Protocol Buffers message to writer", %{file_path: file_path} do
      {:consumer, state, _} = WriterConsumer.init(writer_module: FileWriter)

      # Create a test Protocol Buffers message
      test_message =
        Encoder.encode_client_query(
          <<1, 2, 3, 4>>,
          {127, 0, 0, 1},
          12_345,
          {0, 0, 0, 0},
          5353,
          :udp
        )

      assert {:noreply, [], ^state} = WriterConsumer.handle_events([test_message], self(), state)

      # Verify the message was written to file (FileWriter encodes to Frame Streams)
      {:ok, content} = File.read(file_path)

      # Skip START frame
      {:ok, {:control, :start, _}, rest} = FrameStreams.decode_frame(content)

      # Verify data frame (FileWriter encoded the Protocol Buffers message)
      assert {:ok, {:data, message_data}, _} = FrameStreams.decode_frame(rest)
      assert %Dnstap.Frame{} = Dnstap.Frame.decode(message_data)
    end

    test "writes multiple messages in batch", %{file_path: file_path} do
      {:consumer, state, _} = WriterConsumer.init(writer_module: FileWriter)

      # Create test Protocol Buffers messages
      messages =
        for i <- 1..3 do
          Encoder.encode_client_query(
            <<i>>,
            {127, 0, 0, 1},
            12_345,
            {0, 0, 0, 0},
            5353,
            :udp
          )
        end

      assert {:noreply, [], ^state} = WriterConsumer.handle_events(messages, self(), state)

      # Verify all messages were written
      {:ok, content} = File.read(file_path)
      {:ok, {:control, :start, _}, rest} = FrameStreams.decode_frame(content)

      # Verify 3 data frames
      {:ok, {:data, _}, rest1} = FrameStreams.decode_frame(rest)
      {:ok, {:data, _}, rest2} = FrameStreams.decode_frame(rest1)
      assert {:ok, {:data, _}, _} = FrameStreams.decode_frame(rest2)
    end

    test "handles empty events list gracefully", %{file_path: _file_path} do
      {:consumer, state, _} = WriterConsumer.init(writer_module: FileWriter)

      assert {:noreply, [], ^state} = WriterConsumer.handle_events([], self(), state)
    end

    test "writes messages sequentially maintaining order", %{file_path: file_path} do
      {:consumer, state, _} = WriterConsumer.init(writer_module: FileWriter)

      # Write messages in specific order
      messages =
        for i <- 1..10 do
          Encoder.encode_client_query(
            <<i>>,
            {127, 0, 0, 1},
            10_000 + i,
            {0, 0, 0, 0},
            5353,
            :udp
          )
        end

      {:noreply, [], ^state} = WriterConsumer.handle_events(messages, self(), state)

      # Verify order is preserved
      {:ok, content} = File.read(file_path)
      {:ok, {:control, :start, _}, rest} = FrameStreams.decode_frame(content)

      # Verify all messages in correct order by checking query_port
      {ports, _rest} =
        Enum.reduce(1..10, {[], rest}, fn _i, {acc, data} ->
          {:ok, {:data, message}, remaining} = FrameStreams.decode_frame(data)
          frame = Dnstap.Frame.decode(message)
          {[frame.message.query_port | acc], remaining}
        end)

      assert Enum.reverse(ports) == Enum.map(1..10, fn i -> 10_000 + i end)
    end
  end

  describe "error handling" do
    test "handles writer errors gracefully" do
      file_path = Path.join(@test_dir, "error_test.fstrm")
      {:ok, writer_pid} = FileWriter.start_link(path: file_path)

      {:consumer, state, _} = WriterConsumer.init(writer_module: FileWriter)

      # Close the file to simulate write error
      :sys.get_state(writer_pid)
      |> Map.get(:file)
      |> File.close()

      # Attempt to write should handle error gracefully
      message =
        Encoder.encode_client_query(
          <<1, 2, 3>>,
          {127, 0, 0, 1},
          12_345,
          {0, 0, 0, 0},
          5353,
          :udp
        )

      assert {:noreply, [], ^state} = WriterConsumer.handle_events([message], self(), state)
    end

    test "skips invalid frames (non-binary)" do
      file_path = Path.join(@test_dir, "invalid_test.fstrm")
      {:ok, _writer_pid} = FileWriter.start_link(path: file_path)

      {:consumer, state, _} = WriterConsumer.init(writer_module: FileWriter)

      # Mix valid and invalid events
      events = [
        Encoder.encode_client_query(<<1>>, {127, 0, 0, 1}, 11_111, {0, 0, 0, 0}, 5353, :udp),
        :invalid_event,
        Encoder.encode_client_query(<<2>>, {127, 0, 0, 1}, 22_222, {0, 0, 0, 0}, 5353, :udp)
      ]

      assert {:noreply, [], ^state} = WriterConsumer.handle_events(events, self(), state)

      # Verify only valid Protocol Buffers messages were written (FileWriter encodes to Frame Streams)
      {:ok, content} = File.read(file_path)
      {:ok, {:control, :start, _}, rest} = FrameStreams.decode_frame(content)

      # Check that we got 2 valid data frames
      {:ok, {:data, data1}, rest1} = FrameStreams.decode_frame(rest)
      assert %Dnstap.Frame{} = Dnstap.Frame.decode(data1)

      {:ok, {:data, data2}, _} = FrameStreams.decode_frame(rest1)
      assert %Dnstap.Frame{} = Dnstap.Frame.decode(data2)
    end
  end

  describe "performance - batch writing" do
    test "handles large batch efficiently" do
      file_path = Path.join(@test_dir, "batch_test.fstrm")
      {:ok, _writer_pid} = FileWriter.start_link(path: file_path)

      {:consumer, state, _} = WriterConsumer.init(writer_module: FileWriter)

      # Create 100 Protocol Buffers messages
      messages =
        for i <- 1..100 do
          Encoder.encode_client_query(
            <<i::16>>,
            {127, 0, 0, 1},
            10_000 + i,
            {0, 0, 0, 0},
            5353,
            :udp
          )
        end

      # Measure write time
      {time_us, {:noreply, [], ^state}} =
        :timer.tc(fn -> WriterConsumer.handle_events(messages, self(), state) end)

      # Should complete in reasonable time (< 100ms for 100 messages)
      assert time_us < 100_000

      # Verify all messages were written (FileWriter encodes to Frame Streams)
      {:ok, content} = File.read(file_path)
      {:ok, {:control, :start, _}, rest} = FrameStreams.decode_frame(content)

      # Count data frames
      frame_count = count_data_frames(rest, 0)
      assert frame_count == 100
    end
  end

  # Private helper function for counting data frames
  defp count_data_frames(data, acc) do
    case FrameStreams.decode_frame(data) do
      {:ok, {:data, _}, remaining} -> count_data_frames(remaining, acc + 1)
      _ -> acc
    end
  end
end
