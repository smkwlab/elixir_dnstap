defmodule ElixirDnstap.Writer.FileGenServerTest do
  use ExUnit.Case, async: false

  alias ElixirDnstap.FrameStreams
  alias ElixirDnstap.Writer.File

  @test_dir "/tmp/tenbin_cache_test/dnstap_genserver"
  @content_type "protobuf:dnstap.Dnstap"

  setup do
    # Clean up test directory
    File.rm_rf!(@test_dir)
    File.mkdir_p!(@test_dir)

    on_exit(fn ->
      File.rm_rf!(@test_dir)
    end)

    :ok
  end

  describe "GenServer lifecycle" do
    test "starts under supervision with correct state" do
      file_path = Path.join(@test_dir, "lifecycle_test.fstrm")

      {:ok, pid} = FileWriter.start_link(path: file_path)
      assert Process.alive?(pid)

      # Verify START frame was written
      {:ok, content} = File.read(file_path)

      assert {:ok, {:control, :start, @content_type}, <<>>} =
               FrameStreams.decode_frame(content)

      # Stop the GenServer
      GenServer.stop(pid)
      refute Process.alive?(pid)
    end

    test "writes STOP frame on termination" do
      file_path = Path.join(@test_dir, "stop_frame_test.fstrm")

      {:ok, pid} = FileWriter.start_link(path: file_path)

      # Write a message
      :ok = FileWriter.write(<<1, 2, 3>>)

      # Stop the GenServer
      GenServer.stop(pid)

      # Verify STOP frame was written
      {:ok, content} = File.read(file_path)

      # START frame
      {:ok, {:control, :start, _}, rest1} = FrameStreams.decode_frame(content)

      # DATA frame
      {:ok, {:data, _}, rest2} = FrameStreams.decode_frame(rest1)

      # STOP frame
      assert {:ok, {:control, :stop, nil}, <<>>} = FrameStreams.decode_frame(rest2)
    end
  end

  describe "write/1 with named process" do
    setup do
      file_path = Path.join(@test_dir, "write_test.fstrm")
      {:ok, pid} = FileWriter.start_link(path: file_path)

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
      end)

      %{pid: pid, file_path: file_path}
    end

    test "writes single message", %{file_path: file_path} do
      message = <<1, 2, 3, 4, 5>>

      assert :ok = FileWriter.write(message)

      # Read file and verify frames
      {:ok, content} = File.read(file_path)

      # Skip START frame
      {:ok, {:control, :start, _}, rest} = FrameStreams.decode_frame(content)

      # Verify data frame
      assert {:ok, {:data, ^message}, _} = FrameStreams.decode_frame(rest)
    end

    test "appends multiple messages (critical for Issue #49)", %{file_path: file_path, pid: pid} do
      messages = [
        <<1, 2, 3>>,
        <<4, 5, 6, 7>>,
        <<8, 9>>
      ]

      # Write messages sequentially
      for msg <- messages do
        assert :ok = FileWriter.write(msg)
      end

      # Stop to flush and write STOP frame
      GenServer.stop(pid)

      # Read and verify all frames
      {:ok, content} = File.read(file_path)

      # Skip START frame
      {:ok, {:control, :start, _}, rest} = FrameStreams.decode_frame(content)

      # Verify all data frames are present (not overwritten)
      {decoded_messages, rest_after_data} =
        Enum.reduce(messages, {[], rest}, fn _msg, {acc, data} ->
          {:ok, {:data, decoded_msg}, remaining} = FrameStreams.decode_frame(data)
          {[decoded_msg | acc], remaining}
        end)

      assert Enum.reverse(decoded_messages) == messages

      # Verify STOP frame
      assert {:ok, {:control, :stop, nil}, <<>>} = FrameStreams.decode_frame(rest_after_data)
    end

    test "file size increases with each write (not overwritten)", %{file_path: file_path} do
      # Capture initial size (START frame)
      initial_size = File.stat!(file_path).size

      # Write first message
      FileWriter.write(<<1, 2, 3>>)
      size_after_first = File.stat!(file_path).size
      assert size_after_first > initial_size

      # Write second message
      FileWriter.write(<<4, 5, 6, 7>>)
      size_after_second = File.stat!(file_path).size
      assert size_after_second > size_after_first

      # Write third message
      FileWriter.write(<<8, 9>>)
      size_after_third = File.stat!(file_path).size
      assert size_after_third > size_after_second
    end
  end

  describe "error handling" do
    test "returns error if directory creation fails" do
      # Try to create file in a path where a file already exists
      existing_file = Path.join(@test_dir, "existing_file")
      File.write!(existing_file, "content")

      bad_path = Path.join([existing_file, "subdir", "test.fstrm"])

      # GenServer will exit on init failure
      Process.flag(:trap_exit, true)
      result = FileWriter.start_link(path: bad_path)

      assert match?({:error, _}, result)
    end

    test "returns error if file cannot be opened" do
      # Try to write to a directory path
      Process.flag(:trap_exit, true)
      result = FileWriter.start_link(path: @test_dir)

      assert match?({:error, _}, result)
    end

    test "handles write errors gracefully" do
      file_path = Path.join(@test_dir, "error_test.fstrm")
      {:ok, pid} = FileWriter.start_link(path: file_path)

      # Close the file manually to simulate error
      :sys.get_state(pid)
      |> Map.get(:file)
      |> File.close()

      # Write should return error
      assert {:error, _reason} = FileWriter.write(<<1, 2, 3>>)

      # Process should still be alive (error was handled gracefully)
      assert Process.alive?(pid)

      GenServer.stop(pid)
    end
  end

  describe "concurrent writes" do
    test "handles concurrent write requests safely", %{} do
      file_path = Path.join(@test_dir, "concurrent_test.fstrm")
      {:ok, pid} = FileWriter.start_link(path: file_path)

      # Spawn multiple processes writing concurrently
      tasks =
        for i <- 1..10 do
          Task.async(fn ->
            FileWriter.write(<<i>>)
          end)
        end

      # Wait for all writes to complete
      results = Task.await_many(tasks)

      # All writes should succeed
      assert Enum.all?(results, &(&1 == :ok))

      # Stop and verify file
      GenServer.stop(pid)

      {:ok, content} = File.read(file_path)
      {:ok, {:control, :start, _}, rest} = FrameStreams.decode_frame(content)

      # Count data frames
      frame_count = count_data_frames(rest, 0)

      assert frame_count == 10
    end
  end

  # Private helper function for counting data frames with proper TCO
  defp count_data_frames(data, acc) do
    case FrameStreams.decode_frame(data) do
      {:ok, {:data, _}, remaining} -> count_data_frames(remaining, acc + 1)
      {:ok, {:control, :stop, nil}, _} -> acc
      _ -> acc
    end
  end
end
