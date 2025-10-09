defmodule ElixirDnstap.Writer.UnixSocketTest do
  use ExUnit.Case, async: true

  alias ElixirDnstap.{Encoder, FrameStreams, UnixSocketWriter}

  @test_dir "/tmp/tenbin_cache_test/dnstap_sockets"
  @content_type "protobuf:dnstap.Dnstap"
  # Maximum allowed frame size (same as implementation)
  @max_frame_size 256 * 1024

  setup do
    # Clean up test directory
    File.rm_rf(@test_dir)
    File.mkdir_p!(@test_dir)

    on_exit(fn ->
      File.rm_rf(@test_dir)
    end)

    :ok
  end

  describe "GenServer-based UnixSocketWriter - Basic Functionality" do
    test "init/1 starts GenServer and connects to Unix socket" do
      socket_path = Path.join(@test_dir, "test.sock")

      # Start mock server
      {:ok, server_pid} = start_mock_server(socket_path)

      # Client connects (returns PID)
      {:ok, pid} = UnixSocketWriter.start(path: socket_path, reconnect: false)

      assert is_pid(pid)
      assert Process.alive?(pid)

      # Verify handshake occurred
      assert_receive {:handshake_complete, messages}, 1000

      # Expected handshake from writer (client):
      # 1. READY with content type
      assert {:ok, {:control, :ready, @content_type}, rest1} =
               FrameStreams.decode_frame(messages)

      # 2. START with content type (after receiving ACCEPT from server)
      assert {:ok, {:control, :start, @content_type}, <<>>} = FrameStreams.decode_frame(rest1)

      # Cleanup
      UnixSocketWriter.close(pid)
      stop_mock_server(server_pid)
    end

    test "returns error if socket does not exist" do
      nonexistent_path = Path.join(@test_dir, "nonexistent.sock")

      {:ok, pid} = UnixSocketWriter.start(path: nonexistent_path, reconnect: false, timeout: 100)

      # Should start but fail to connect
      assert is_pid(pid)

      # Write should fail
      result = UnixSocketWriter.write(pid, <<1, 2, 3>>)
      assert {:error, _reason} = result

      UnixSocketWriter.close(pid)
    end

    test "returns error if path is required" do
      assert {:error, :path_required} = UnixSocketWriter.start(%{})
    end

    test "write/2 sends dnstap message to Unix socket" do
      socket_path = Path.join(@test_dir, "test_write.sock")

      # Prepare test message
      packet = <<0x12, 0x34, 0x01, 0x00>>
      client_addr = {192, 168, 1, 100}
      client_port = 54_321
      server_addr = {127, 0, 0, 1}
      server_port = 5353

      encoded_message =
        Encoder.encode_client_query(
          packet,
          client_addr,
          client_port,
          server_addr,
          server_port,
          :udp
        )

      # Start server
      {:ok, server_pid} = start_mock_server(socket_path)

      # Client connects and writes
      {:ok, pid} = UnixSocketWriter.start(path: socket_path, reconnect: false)

      # Clear handshake message
      assert_receive {:handshake_complete, _}, 1000

      :ok = UnixSocketWriter.write(pid, encoded_message)

      # Verify server received the message
      assert_receive {:data_received, frame}, 1000
      {:ok, {:data, received_message}, <<>>} = FrameStreams.decode_frame(frame)
      assert received_message == encoded_message

      # Cleanup
      UnixSocketWriter.close(pid)
      stop_mock_server(server_pid)
    end

    test "writes multiple messages" do
      socket_path = Path.join(@test_dir, "test_multiple.sock")
      {:ok, server_pid} = start_mock_server(socket_path)

      {:ok, pid} = UnixSocketWriter.start(path: socket_path, reconnect: false)

      # Clear handshake message
      assert_receive {:handshake_complete, _}, 1000

      messages = [<<1, 2, 3>>, <<4, 5, 6, 7>>, <<8, 9>>]

      for msg <- messages do
        assert :ok = UnixSocketWriter.write(pid, msg)
      end

      # Collect all received messages
      received =
        for _msg <- messages do
          assert_receive {:data_received, data}, 1000
          {:ok, {:data, decoded}, <<>>} = FrameStreams.decode_frame(data)
          decoded
        end

      assert received == messages

      UnixSocketWriter.close(pid)
      stop_mock_server(server_pid)
    end

    test "handles large messages (up to max frame size)" do
      socket_path = Path.join(@test_dir, "test_large.sock")
      {:ok, server_pid} = start_mock_server(socket_path)

      {:ok, pid} = UnixSocketWriter.start(path: socket_path, reconnect: false)

      # Clear handshake message
      assert_receive {:handshake_complete, _}, 1000

      # Create a message at the maximum allowed size (256KB)
      large_message = :crypto.strong_rand_bytes(@max_frame_size)

      assert :ok = UnixSocketWriter.write(pid, large_message)

      assert_receive {:data_received, data}, 5000

      assert {:ok, {:data, ^large_message}, <<>>} = FrameStreams.decode_frame(data)

      UnixSocketWriter.close(pid)
      stop_mock_server(server_pid)
    end

    test "rejects messages exceeding max frame size" do
      socket_path = Path.join(@test_dir, "test_too_large.sock")
      {:ok, server_pid} = start_mock_server(socket_path)

      {:ok, pid} = UnixSocketWriter.start(path: socket_path, reconnect: false)

      # Clear handshake message
      assert_receive {:handshake_complete, _}, 1000

      # Create a message exceeding the maximum allowed size
      too_large_message = :crypto.strong_rand_bytes(@max_frame_size + 1)

      # Should return error
      assert {:error, {:frame_too_large, _, _}} = UnixSocketWriter.write(pid, too_large_message)

      UnixSocketWriter.close(pid)
      stop_mock_server(server_pid)
    end

    test "close/1 sends FINISH frame and stops GenServer" do
      socket_path = Path.join(@test_dir, "test_close.sock")
      {:ok, server_pid} = start_mock_server(socket_path)

      {:ok, pid} = UnixSocketWriter.start(path: socket_path, reconnect: false)

      # Clear handshake message
      assert_receive {:handshake_complete, _}, 1000

      assert :ok = UnixSocketWriter.close(pid)

      # Verify process is stopped
      refute Process.alive?(pid)

      # Verify server received FINISH frame
      assert_receive {:control_received, control_data}, 1000
      assert {:ok, {:control, :finish, nil}, <<>>} = FrameStreams.decode_frame(control_data)

      stop_mock_server(server_pid)
    end
  end

  describe "Reconnection Logic" do
    test "automatically reconnects on initial connection failure" do
      socket_path = Path.join(@test_dir, "test_reconnect.sock")

      # Start client first (server doesn't exist yet)
      {:ok, pid} =
        UnixSocketWriter.start(
          path: socket_path,
          reconnect: true,
          reconnect_interval: 100,
          max_reconnect_attempts: 10
        )

      # Wait a bit for initial connection attempts
      Process.sleep(200)

      # Start server after delay to simulate reconnection
      {:ok, server_pid} = start_mock_server(socket_path)

      # Wait for handshake
      assert_receive {:handshake_complete, _}, 2000

      # Should be able to write
      :ok = UnixSocketWriter.write(pid, <<1, 2, 3>>)

      assert_receive {:data_received, _}, 1000

      UnixSocketWriter.close(pid)
      stop_mock_server(server_pid)
    end

    test "stops retrying after max_reconnect_attempts" do
      socket_path = Path.join(@test_dir, "test_max_attempts.sock")

      # Start client with limited retry attempts (server doesn't exist)
      {:ok, pid} =
        UnixSocketWriter.start(
          path: socket_path,
          reconnect: true,
          reconnect_interval: 50,
          max_reconnect_attempts: 3
        )

      # Wait for all attempts to exhaust
      Process.sleep(500)

      # Write should fail
      result = UnixSocketWriter.write(pid, <<1, 2, 3>>)
      assert {:error, {:not_connected, _status}} = result

      UnixSocketWriter.close(pid)
    end
  end

  describe "Frame Streams protocol compliance" do
    test "performs correct bi-directional handshake" do
      socket_path = Path.join(@test_dir, "protocol_test.sock")
      {:ok, server_pid} = start_mock_server(socket_path)

      {:ok, pid} = UnixSocketWriter.start(path: socket_path, reconnect: false)

      # Verify complete handshake sequence
      assert_receive {:handshake_complete, client_messages}, 1000

      # Client sends: READY
      {:ok, {:control, :ready, @content_type}, rest1} =
        FrameStreams.decode_frame(client_messages)

      # Client sends: START (after receiving ACCEPT)
      {:ok, {:control, :start, @content_type}, <<>>} = FrameStreams.decode_frame(rest1)

      # Write and close
      UnixSocketWriter.write(pid, <<1, 2, 3>>)
      assert_receive {:data_received, _}, 1000

      UnixSocketWriter.close(pid)
      assert_receive {:control_received, finish_frame}, 1000

      # Verify FINISH frame
      {:ok, {:control, :finish, nil}, <<>>} = FrameStreams.decode_frame(finish_frame)

      stop_mock_server(server_pid)
    end
  end

  # Helper functions for mock server

  defp start_mock_server(socket_path) do
    test_pid = self()

    server_pid =
      spawn_link(fn ->
        mock_server_loop(socket_path, test_pid)
      end)

    # Wait for server to be ready
    assert_receive :server_ready, 1000

    {:ok, server_pid}
  end

  defp stop_mock_server(server_pid) do
    Process.exit(server_pid, :normal)
  end

  defp mock_server_loop(socket_path, test_pid) do
    # Remove existing socket file if it exists
    case File.rm(socket_path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> raise "Failed to remove socket file: #{inspect(reason)}"
    end

    # Create Unix domain socket server
    {:ok, listen_socket} =
      :gen_tcp.listen(0, [
        :binary,
        {:ifaddr, {:local, String.to_charlist(socket_path)}},
        {:active, false},
        {:packet, 0}
      ])

    send(test_pid, :server_ready)

    # Accept connection
    {:ok, client_socket} = :gen_tcp.accept(listen_socket)

    # Perform handshake
    handshake_messages = perform_server_handshake(client_socket)
    send(test_pid, {:handshake_complete, handshake_messages})

    # Handle subsequent messages
    handle_client_messages(client_socket, test_pid)

    :gen_tcp.close(client_socket)
    :gen_tcp.close(listen_socket)
  end

  defp perform_server_handshake(socket) do
    # Receive READY from client
    {:ok, ready_frame} = receive_frame(socket)

    # Send ACCEPT
    accept_frame = FrameStreams.encode_control_frame(:accept, @content_type)
    :ok = :gen_tcp.send(socket, accept_frame)

    # Receive START from client
    {:ok, start_frame} = receive_frame(socket)

    # Return all client messages
    ready_frame <> start_frame
  end

  defp handle_client_messages(socket, test_pid) do
    case receive_frame(socket) do
      {:ok, frame} ->
        # Classify and forward to test
        case FrameStreams.decode_frame(frame) do
          {:ok, {:data, _payload}, _} ->
            send(test_pid, {:data_received, frame})
            handle_client_messages(socket, test_pid)

          {:ok, {:control, _type, _content_type}, _} ->
            send(test_pid, {:control_received, frame})
            # FINISH received, stop
            :ok

          _ ->
            handle_client_messages(socket, test_pid)
        end

      {:error, :closed} ->
        :ok
    end
  end

  defp receive_frame(socket) do
    # Read length
    case :gen_tcp.recv(socket, 4) do
      {:ok, <<length::32-big>>} ->
        if length == 0 do
          # Control frame - read control length
          {:ok, <<control_length::32-big>>} = :gen_tcp.recv(socket, 4)
          {:ok, control_payload} = :gen_tcp.recv(socket, control_length)
          {:ok, <<0::32-big, control_length::32-big, control_payload::binary>>}
        else
          # Data frame
          {:ok, payload} = :gen_tcp.recv(socket, length)
          {:ok, <<length::32-big, payload::binary>>}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end
end
