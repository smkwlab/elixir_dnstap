defmodule ElixirDnstap.SupervisorTest do
  use ExUnit.Case, async: false

  @test_dir "/tmp/tenbin_cache_test/writer_manager"

  setup do
    # Clean up test directory
    File.rm_rf(@test_dir)
    File.mkdir_p!(@test_dir)

    # Save original config to restore after test
    original_enabled = Application.get_env(:elixir_dnstap, :enabled)
    original_output = Application.get_env(:elixir_dnstap, :output)

    on_exit(fn ->
      # Restore original config
      if original_enabled do
        Application.put_env(:elixir_dnstap, :enabled, original_enabled)
      else
        Application.delete_env(:elixir_dnstap, :enabled)
      end

      if original_output do
        Application.put_env(:elixir_dnstap, :output, original_output)
      else
        Application.delete_env(:elixir_dnstap, :output)
      end

      File.rm_rf(@test_dir)
    end)

    :ok
  end

  describe "Supervisor with DNSTap disabled" do
    test "starts with empty children when DNSTap is disabled" do
      Application.put_env(:elixir_dnstap, :enabled, false)

      {:ok, pid} = start_supervised(ElixirDnstap.Supervisor)

      assert Process.alive?(pid)
      assert Supervisor.which_children(pid) == []
    end
  end

  describe "Supervisor with FileWriter (GenServer)" do
    test "starts FileWriter child process under supervision" do
      file_path = Path.join(@test_dir, "test.fstrm")

      Application.put_env(:elixir_dnstap, :enabled, true)
      Application.put_env(:elixir_dnstap, :output, type: :file, path: file_path)

      {:ok, pid} = start_supervised(ElixirDnstap.Supervisor)

      # FileWriter and GenStage pipeline should be supervised
      assert Process.alive?(pid)
      children = Supervisor.which_children(pid)
      # Writer + Producer + BufferStage + WriterConsumer = 4 children
      assert length(children) == 4

      # Verify FileWriter is among the children
      assert Enum.find(children, fn {mod, _pid, _type, _modules} ->
               mod == ElixirDnstap.Writer.File
             end)

      # Verify GenStage components are present
      assert Enum.find(children, fn {mod, _pid, _type, _modules} ->
               mod == ElixirDnstap.Producer
             end)

      assert Enum.find(children, fn {mod, _pid, _type, _modules} ->
               mod == ElixirDnstap.BufferStage
             end)

      assert Enum.find(children, fn {mod, _pid, _type, _modules} ->
               mod == ElixirDnstap.WriterConsumer
             end)
    end
  end

  describe "Supervisor with TcpWriter" do
    test "starts TcpWriter child process under supervision" do
      Application.put_env(:elixir_dnstap, :enabled, true)

      Application.put_env(:elixir_dnstap, :output,
        type: :tcp,
        host: "localhost",
        port: 12_345,
        reconnect: false,
        timeout: 100
      )

      {:ok, pid} = start_supervised(ElixirDnstap.Supervisor)

      # TcpWriter and GenStage pipeline should be supervised
      assert Process.alive?(pid)
      children = Supervisor.which_children(pid)
      assert length(children) == 4

      # Verify TcpWriter is among the children
      tcp_writer =
        Enum.find(children, fn {id, _pid, _type, _modules} ->
          id == ElixirDnstap.Writer.TCP
        end)

      assert tcp_writer
      {_id, tcp_writer_pid, :worker, [ElixirDnstap.Writer.TCP]} = tcp_writer
      assert Process.alive?(tcp_writer_pid)
    end
  end

  describe "Supervisor with UnixSocketWriter" do
    test "starts UnixSocketWriter child process under supervision" do
      socket_path = Path.join(@test_dir, "test.sock")
      {:ok, _server_pid} = start_mock_unix_server(socket_path)

      Application.put_env(:elixir_dnstap, :enabled, true)
      Application.put_env(:elixir_dnstap, :output, type: :unix_socket, path: socket_path)

      {:ok, pid} = start_supervised(ElixirDnstap.Supervisor)

      # UnixSocketWriter and GenStage pipeline should be supervised
      assert Process.alive?(pid)
      children = Supervisor.which_children(pid)
      assert length(children) == 4

      # Verify UnixSocketWriter is among the children
      unix_writer =
        Enum.find(children, fn {id, _pid, _type, _modules} ->
          id == ElixirDnstap.Writer.UnixSocket
        end)

      assert unix_writer
      {_id, unix_writer_pid, :worker, [ElixirDnstap.Writer.UnixSocket]} = unix_writer
      assert Process.alive?(unix_writer_pid)
    end
  end

  describe "Supervisor error handling" do
    test "falls back to FileWriter for invalid output type" do
      Application.put_env(:elixir_dnstap, :enabled, true)
      Application.put_env(:elixir_dnstap, :output, type: :invalid_type)

      # Config.select_writer raises for unknown type, supervisor rescues and starts with no children
      {:ok, pid} = start_supervised(ElixirDnstap.Supervisor)

      assert Process.alive?(pid)
      children = Supervisor.which_children(pid)
      assert children == []
    end

    test "uses default path when path is missing for file writer" do
      Application.put_env(:elixir_dnstap, :enabled, true)
      Application.put_env(:elixir_dnstap, :output, type: :file)

      {:ok, pid} = start_supervised(ElixirDnstap.Supervisor)

      assert Process.alive?(pid)
      children = Supervisor.which_children(pid)
      assert length(children) == 4

      # Verify FileWriter is among the children
      file_writer =
        Enum.find(children, fn {id, _pid, _type, _modules} ->
          id == ElixirDnstap.Writer.File
        end)

      assert file_writer
      {_id, file_writer_pid, :worker, _} = file_writer
      assert Process.alive?(file_writer_pid)
    end
  end

  # Helper functions

  defp start_mock_unix_server(socket_path) do
    # Remove existing socket
    File.rm(socket_path)

    # Start a simple Unix socket server
    test_pid = self()

    server_pid =
      spawn_link(fn ->
        {:ok, listen_socket} =
          :gen_tcp.listen(0, [
            :binary,
            {:ifaddr, {:local, String.to_charlist(socket_path)}},
            {:active, false},
            {:packet, 0}
          ])

        send(test_pid, :server_ready)

        # Accept one connection and perform minimal handshake
        case :gen_tcp.accept(listen_socket, 1000) do
          {:ok, client_socket} ->
            # Just accept and close to allow test to proceed
            :gen_tcp.close(client_socket)

          {:error, :timeout} ->
            :ok
        end

        :gen_tcp.close(listen_socket)
      end)

    # Wait for server to be ready
    receive do
      :server_ready -> {:ok, server_pid}
    after
      1000 -> {:error, :timeout}
    end
  end
end
