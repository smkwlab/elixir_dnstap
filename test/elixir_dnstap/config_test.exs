defmodule ElixirDnstap.ConfigTest do
  use ExUnit.Case, async: true

  alias ElixirDnstap.Config

  describe "enabled?/0" do
    test "returns false by default" do
      Application.delete_env(:elixir_dnstap, :enabled)
      refute Config.enabled?()
    end

    test "returns true when enabled" do
      Application.put_env(:elixir_dnstap, :enabled, true)
      assert Config.enabled?()

      # Cleanup
      Application.delete_env(:elixir_dnstap, :enabled)
    end
  end

  describe "get_output/0" do
    test "returns empty list by default" do
      Application.delete_env(:elixir_dnstap, :output)
      assert Config.get_output() == []
    end

    test "returns configured output" do
      output_config = [type: :file, path: "/tmp/test.fstrm"]
      Application.put_env(:elixir_dnstap, :output, output_config)
      assert Config.get_output() == output_config

      # Cleanup
      Application.delete_env(:elixir_dnstap, :output)
    end
  end

  describe "get_output_type/0" do
    test "returns :file by default" do
      Application.delete_env(:elixir_dnstap, :output)
      assert Config.get_output_type() == :file
    end

    test "returns configured type" do
      Application.put_env(:elixir_dnstap, :output, type: :tcp)
      assert Config.get_output_type() == :tcp

      # Cleanup
      Application.delete_env(:elixir_dnstap, :output)
    end
  end

  describe "get_config_value/3" do
    test "gets value from keyword list" do
      config = [host: "localhost", port: 53]
      assert Config.get_config_value(config, :host) == "localhost"
      assert Config.get_config_value(config, :port) == 53
    end

    test "gets value from map" do
      config = %{host: "localhost", port: 53}
      assert Config.get_config_value(config, :host) == "localhost"
      assert Config.get_config_value(config, :port) == 53
    end

    test "returns default when key not found" do
      config = [host: "localhost"]
      assert Config.get_config_value(config, :port, 5353) == 5353
    end

    test "returns nil by default when key not found" do
      config = []
      assert Config.get_config_value(config, :missing) == nil
    end
  end

  describe "select_writer/0" do
    test "raises when DNSTap is not enabled" do
      Application.delete_env(:elixir_dnstap, :enabled)

      assert_raise RuntimeError, "DNSTap is not enabled in configuration", fn ->
        Config.select_writer()
      end
    end

    test "selects file writer by default" do
      Application.put_env(:elixir_dnstap, :enabled, true)
      Application.put_env(:elixir_dnstap, :output, [])

      {writer_module, writer_config} = Config.select_writer()

      assert writer_module == ElixirDnstap.Writer.File
      assert writer_config[:path] == "log/dnstap.fstrm"

      # Cleanup
      Application.delete_env(:elixir_dnstap, :enabled)
      Application.delete_env(:elixir_dnstap, :output)
    end

    test "selects unix socket writer" do
      Application.put_env(:elixir_dnstap, :enabled, true)
      Application.put_env(:elixir_dnstap, :output, type: :unix_socket, path: "/tmp/test.sock")

      {writer_module, writer_config} = Config.select_writer()

      assert writer_module == ElixirDnstap.Writer.UnixSocket
      assert writer_config[:path] == "/tmp/test.sock"

      # Cleanup
      Application.delete_env(:elixir_dnstap, :enabled)
      Application.delete_env(:elixir_dnstap, :output)
    end

    test "selects TCP writer" do
      Application.put_env(:elixir_dnstap, :enabled, true)

      Application.put_env(:elixir_dnstap, :output,
        type: :tcp,
        host: "127.0.0.1",
        port: 6000
      )

      {writer_module, writer_config} = Config.select_writer()

      assert writer_module == ElixirDnstap.Writer.TCP
      assert writer_config[:host] == "127.0.0.1"
      assert writer_config[:port] == 6000
      assert writer_config[:timeout] == 5000
      assert writer_config[:bidirectional] == true
      assert writer_config[:reconnect] == true

      # Cleanup
      Application.delete_env(:elixir_dnstap, :enabled)
      Application.delete_env(:elixir_dnstap, :output)
    end

    test "raises when unix socket path is missing" do
      Application.put_env(:elixir_dnstap, :enabled, true)
      Application.put_env(:elixir_dnstap, :output, type: :unix_socket)

      assert_raise RuntimeError,
                   "DNSTap Unix socket configuration error: path is required for unix_socket output",
                   fn ->
                     Config.select_writer()
                   end

      # Cleanup
      Application.delete_env(:elixir_dnstap, :enabled)
      Application.delete_env(:elixir_dnstap, :output)
    end

    test "raises when TCP host is missing" do
      Application.put_env(:elixir_dnstap, :enabled, true)
      Application.put_env(:elixir_dnstap, :output, type: :tcp, port: 6000)

      assert_raise RuntimeError, "DNSTap TCP configuration error: host is required for TCP output", fn ->
        Config.select_writer()
      end

      # Cleanup
      Application.delete_env(:elixir_dnstap, :enabled)
      Application.delete_env(:elixir_dnstap, :output)
    end

    test "raises when TCP port is missing" do
      Application.put_env(:elixir_dnstap, :enabled, true)
      Application.put_env(:elixir_dnstap, :output, type: :tcp, host: "127.0.0.1")

      assert_raise RuntimeError, "DNSTap TCP configuration error: port is required for TCP output", fn ->
        Config.select_writer()
      end

      # Cleanup
      Application.delete_env(:elixir_dnstap, :enabled)
      Application.delete_env(:elixir_dnstap, :output)
    end

    test "raises when TCP port is invalid" do
      Application.put_env(:elixir_dnstap, :enabled, true)
      Application.put_env(:elixir_dnstap, :output, type: :tcp, host: "127.0.0.1", port: 70000)

      assert_raise RuntimeError,
                   "DNSTap TCP configuration error: port must be between 1 and 65535, got 70000",
                   fn ->
                     Config.select_writer()
                   end

      # Cleanup
      Application.delete_env(:elixir_dnstap, :enabled)
      Application.delete_env(:elixir_dnstap, :output)
    end
  end
end
