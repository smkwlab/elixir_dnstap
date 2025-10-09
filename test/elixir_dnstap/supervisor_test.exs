defmodule ElixirDnstap.SupervisorTest do
  use ExUnit.Case, async: false

  alias ElixirDnstap.Config
  alias ElixirDnstap.Supervisor

  @test_dir "/tmp/tenbin_cache_test/writer_manager"

  setup do
    # Clean up test directory
    File.rm_rf!(@test_dir)
    File.mkdir_p!(@test_dir)

    # Start ConfigParser (required for WriterManager)
    start_supervised!(ConfigParser)

    on_exit(fn ->
      File.rm_rf!(@test_dir)
    end)

    :ok
  end

  # Helper function to update DNSTap configuration
  defp set_dnstap_config(config) do
    Agent.update(ConfigParser, fn state ->
      Map.put(state, "dnstap", config)
    end)
  end

  describe "WriterManager with DNSTap disabled" do
    test "starts with empty children when DNSTap is disabled" do
      # DNSTap disabled
      set_dnstap_config(%{"enabled" => false})

      {:ok, pid} = start_supervised({WriterManager, []})

      # Supervisor should start but have no children
      assert Process.alive?(pid)
      assert Supervisor.which_children(pid) == []
    end
  end

  describe "WriterManager with FileWriter (GenServer)" do
    test "starts FileWriter child process under supervision" do
      file_path = Path.join(@test_dir, "test.fstrm")

      # Configure DNSTap with FileWriter
      set_dnstap_config(%{
        "enabled" => true,
        "output" => %{
          "type" => "file",
          "path" => file_path
        }
      })

      {:ok, pid} = start_supervised({WriterManager, []})

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

  describe "WriterManager with TcpWriter" do
    test "starts TcpWriter child process under supervision" do
      # Configure DNSTap with TcpWriter
      set_dnstap_config(%{
        "enabled" => true,
        "output" => %{
          "type" => "tcp",
          "host" => "localhost",
          "port" => 12_345,
          "reconnect" => false,
          "timeout" => 100
        }
      })

      {:ok, pid} = start_supervised({WriterManager, []})

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

  describe "WriterManager with UnixSocketWriter" do
    test "starts UnixSocketWriter child process under supervision" do
      socket_path = Path.join(@test_dir, "test.sock")
      {:ok, _server_pid} = start_mock_unix_server(socket_path)

      # Configure DNSTap with UnixSocketWriter
      set_dnstap_config(%{
        "enabled" => true,
        "output" => %{
          "type" => "unix_socket",
          "path" => socket_path,
          "reconnect" => false
        }
      })

      {:ok, pid} = start_supervised({WriterManager, []})

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

  describe "WriterManager error handling" do
    test "falls back to FileWriter for invalid output type" do
      # Configure with invalid output type
      set_dnstap_config(%{
        "enabled" => true,
        "output" => %{
          "type" => "invalid_type"
        }
      })

      # Should fall back to FileWriter with default path
      {:ok, pid} = start_supervised({WriterManager, []})

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

    test "uses default path when path is missing for file writer" do
      # Configure with missing path for file writer
      set_dnstap_config(%{
        "enabled" => true,
        "output" => %{
          "type" => "file"
          # Missing "path" - should use default "log/dnstap.log"
        }
      })

      # Should start with FileWriter using default path
      {:ok, pid} = start_supervised({WriterManager, []})

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
