defmodule ElixirDnstap.Writer.TCPGenServerTest do
  use ExUnit.Case, async: true

  alias ElixirDnstap.{Encoder, FrameStreams, TcpWriter}

  @content_type "protobuf:dnstap.Dnstap"

  setup do
    # Start a mock TCP server for testing
    {:ok, listen_socket} =
      :gen_tcp.listen(0, [
        :binary,
        {:packet, 0},
        {:active, false},
        {:reuseaddr, true}
      ])

    {:ok, port} = :inet.port(listen_socket)

    on_exit(fn ->
      :gen_tcp.close(listen_socket)
    end)

    {:ok, listen_socket: listen_socket, port: port}
  end

  describe "GenServer-based TcpWriter - Basic Functionality" do
    test "init/1 starts GenServer and connects to TCP server", %{
      listen_socket: listen_socket,
      port: port
    } do
      # Start async server task
      server_task =
        Task.async(fn ->
          {:ok, client_socket} = :gen_tcp.accept(listen_socket, 5000)
          perform_server_handshake(client_socket)
          client_socket
        end)

      # Client connects (returns PID)
      {:ok, pid} = TcpWriter.start(host: "localhost", port: port, reconnect: false)

      assert is_pid(pid)
      assert Process.alive?(pid)

      # Wait for server task
      client_socket = Task.await(server_task)

      # Cleanup
      TcpWriter.close(pid)
      :gen_tcp.close(client_socket)
    end

    test "write/2 sends dnstap message to TCP socket", %{
      listen_socket: listen_socket,
      port: port
    } do
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
      server_task =
        Task.async(fn ->
          {:ok, client_socket} = :gen_tcp.accept(listen_socket, 5000)
          perform_server_handshake(client_socket)

          # Receive data frame
          {:ok, frame} = receive_frame(client_socket)
          {:ok, {:data, received_message}, <<>>} = FrameStreams.decode_frame(frame)

          {client_socket, received_message}
        end)

      # Client connects and writes
      {:ok, pid} = TcpWriter.start(host: "localhost", port: port, reconnect: false)
      :ok = TcpWriter.write(pid, encoded_message)

      # Verify server received the message
      {client_socket, received_message} = Task.await(server_task)
      assert received_message == encoded_message

      # Cleanup
      TcpWriter.close(pid)
      :gen_tcp.close(client_socket)
    end

    test "write/2 returns error when connection is lost" do
      # This test will be implemented after reconnection logic
      # For now, just verify basic error handling
      {:ok, pid} = TcpWriter.start(host: "localhost", port: 9999, timeout: 100, reconnect: false)

      # Should fail because there's no server
      result = TcpWriter.write(pid, <<1, 2, 3>>)
      assert {:error, _reason} = result

      TcpWriter.close(pid)
    end

    test "close/1 sends FINISH frame and stops GenServer", %{
      listen_socket: listen_socket,
      port: port
    } do
      # Start server
      server_task =
        Task.async(fn ->
          {:ok, client_socket} = :gen_tcp.accept(listen_socket, 5000)
          perform_server_handshake(client_socket)

          # Wait for FINISH frame
          {:ok, frame} = receive_frame(client_socket)
          {:ok, {:control, :finish, nil}, <<>>} = FrameStreams.decode_frame(frame)

          client_socket
        end)

      # Client connects and closes
      {:ok, pid} = TcpWriter.start(host: "localhost", port: port, reconnect: false)
      :ok = TcpWriter.close(pid)

      # Verify process is stopped
      refute Process.alive?(pid)

      # Verify server received FINISH
      client_socket = Task.await(server_task)
      :gen_tcp.close(client_socket)
    end
  end

  describe "Reconnection Logic" do
    test "automatically reconnects on initial connection failure" do
      # Start server after delay to simulate reconnection
      port = 19_999

      spawn(fn ->
        Process.sleep(500)

        {:ok, listen_socket} =
          :gen_tcp.listen(port, [
            :binary,
            {:packet, 0},
            {:active, false},
            {:reuseaddr, true}
          ])

        {:ok, client_socket} = :gen_tcp.accept(listen_socket, 5000)
        perform_server_handshake(client_socket)

        # Keep server alive
        Process.sleep(2000)
        :gen_tcp.close(client_socket)
        :gen_tcp.close(listen_socket)
      end)

      # Client should retry connection
      {:ok, pid} =
        TcpWriter.start(
          host: "localhost",
          port: port,
          reconnect: true,
          reconnect_interval: 100,
          max_reconnect_attempts: 10
        )

      # Wait for connection to succeed by polling
      assert eventually(fn ->
               case TcpWriter.write(pid, <<1, 2, 3>>) do
                 :ok -> true
                 {:error, _} -> false
               end
             end)

      # Verify write works
      :ok = TcpWriter.write(pid, <<1, 2, 3>>)

      TcpWriter.close(pid)
    end

    test "uses exponential backoff for reconnection attempts" do
      # This test will verify backoff intervals
      # Implementation TBD
    end

    test "stops retrying after max_reconnect_attempts" do
      # This test will verify maximum retry limit
      # Implementation TBD
    end
  end

  # Helper functions for mock server

  defp perform_server_handshake(socket) do
    # 1. Receive READY frame
    {:ok, ready_frame} = receive_frame(socket)
    {:ok, {:control, :ready, @content_type}, <<>>} = FrameStreams.decode_frame(ready_frame)

    # 2. Send ACCEPT frame
    accept_frame = FrameStreams.encode_control_frame(:accept, @content_type)
    :ok = :gen_tcp.send(socket, accept_frame)

    # 3. Receive START frame
    {:ok, start_frame} = receive_frame(socket)
    {:ok, {:control, :start, @content_type}, <<>>} = FrameStreams.decode_frame(start_frame)

    :ok
  end

  defp receive_frame(socket) do
    # Read length field (4 bytes)
    case :gen_tcp.recv(socket, 4, 5000) do
      {:ok, <<0::32-big>>} ->
        # Control frame
        {:ok, <<control_length::32-big>>} = :gen_tcp.recv(socket, 4, 5000)
        {:ok, control_payload} = :gen_tcp.recv(socket, control_length, 5000)
        {:ok, <<0::32-big, control_length::32-big, control_payload::binary>>}

      {:ok, <<length::32-big>>} ->
        # Data frame
        {:ok, payload} = :gen_tcp.recv(socket, length, 5000)
        {:ok, <<length::32-big, payload::binary>>}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Helper function to poll a condition until it succeeds or times out
  defp eventually(func, timeout \\ 3000, interval \\ 50) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_eventually(func, deadline, interval)
  end

  defp do_eventually(func, deadline, interval) do
    if func.() do
      true
    else
      now = System.monotonic_time(:millisecond)

      if now >= deadline do
        false
      else
        Process.sleep(interval)
        do_eventually(func, deadline, interval)
      end
    end
  end
end
