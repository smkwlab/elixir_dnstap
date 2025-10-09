defmodule ElixirDnstap.Config do
  @moduledoc """
  Configuration helper for ElixirDNSTap.

  This module provides utility functions for extracting configuration values
  from Application environment. It replaces the YAML-based ConfigParser
  from tenbin_cache with Application config-based approach.

  ## Configuration Structure

  ```elixir
  config :elixir_dnstap,
    enabled: true,
    output: [
      type: :tcp,
      host: "127.0.0.1",
      port: 6000,
      bidirectional: true,
      reconnect: true,
      reconnect_interval: 1000,
      max_reconnect_interval: 60_000,
      max_reconnect_attempts: :infinity
    ]
  ```

  ## Usage

  ```elixir
  # Check if DNSTap is enabled
  ElixirDnstap.Config.enabled?()

  # Get output type
  ElixirDnstap.Config.get_output_type()

  # Select writer module and config
  {writer_module, writer_config} = ElixirDnstap.Config.select_writer()
  ```
  """

  @doc """
  Check if DNSTap is enabled.

  ## Returns

  - `true` - DNSTap is enabled
  - `false` - DNSTap is disabled (default)
  """
  @spec enabled?() :: boolean()
  def enabled? do
    Application.get_env(:elixir_dnstap, :enabled, false)
  end

  @doc """
  Get output configuration.

  ## Returns

  Keyword list with output configuration
  """
  @spec get_output() :: keyword()
  def get_output do
    Application.get_env(:elixir_dnstap, :output, [])
  end

  @doc """
  Get DNSTap output type.

  Returns `:file`, `:unix_socket`, or `:tcp` based on the configuration.

  ## Returns

  - `:file` - File output (default)
  - `:unix_socket` - Unix domain socket output
  - `:tcp` - TCP socket output
  """
  @spec get_output_type() :: :file | :unix_socket | :tcp
  def get_output_type do
    output = get_output()
    Keyword.get(output, :type, :file)
  end

  @doc """
  Get a configuration value from a keyword list or map.

  ## Parameters

  - `config` - Configuration as keyword list or map
  - `key` - Key to retrieve
  - `default` - Default value if key not found (default: nil)

  ## Returns

  The value associated with the key, or the default value if not found.

  ## Examples

      iex> ElixirDnstap.Config.get_config_value([path: "/tmp/test.sock"], :path)
      "/tmp/test.sock"

      iex> ElixirDnstap.Config.get_config_value(%{path: "/tmp/test.sock"}, :path)
      "/tmp/test.sock"

      iex> ElixirDnstap.Config.get_config_value([], :missing, "default")
      "default"
  """
  @spec get_config_value(keyword() | map(), atom(), any()) :: any()
  def get_config_value(config, key, default \\ nil)

  def get_config_value(config, key, default) when is_list(config) do
    Keyword.get(config, key, default)
  end

  def get_config_value(config, key, default) when is_map(config) do
    Map.get(config, key, default)
  end

  @doc """
  Select the appropriate DNSTap writer module and configuration.

  ## Returns

  A tuple of `{writer_module, config}` where:
  - `writer_module` is the module to use (Writer.File, Writer.UnixSocket, or Writer.TCP)
  - `config` is the configuration for that writer

  ## Raises

  Raises `RuntimeError` if DNSTap is not enabled or configuration is invalid.
  """
  @spec select_writer() :: {module(), keyword()}
  def select_writer do
    unless enabled?() do
      raise "DNSTap is not enabled in configuration"
    end

    output_type = get_output_type()
    output = get_output()

    case output_type do
      :file ->
        {ElixirDnstap.Writer.File, get_file_writer_config(output)}

      :unix_socket ->
        {ElixirDnstap.Writer.UnixSocket, get_unix_socket_writer_config(output)}

      :tcp ->
        {ElixirDnstap.Writer.TCP, get_tcp_writer_config(output)}
    end
  end

  # Private helpers for writer configuration

  defp get_file_writer_config(output) do
    path = Keyword.get(output, :path, "log/dnstap.fstrm")
    [path: path]
  end

  defp get_unix_socket_writer_config(output) do
    path = Keyword.get(output, :path)

    unless path do
      raise "DNSTap Unix socket configuration error: path is required for unix_socket output"
    end

    [path: path]
  end

  defp get_tcp_writer_config(output) do
    host = Keyword.get(output, :host)
    port = Keyword.get(output, :port)

    unless host do
      raise "DNSTap TCP configuration error: host is required for TCP output"
    end

    unless port do
      raise "DNSTap TCP configuration error: port is required for TCP output"
    end

    unless is_integer(port) and port >= 1 and port <= 65_535 do
      raise "DNSTap TCP configuration error: port must be between 1 and 65535, got #{port}"
    end

    [
      host: host,
      port: port,
      timeout: Keyword.get(output, :timeout, 5000),
      bidirectional: Keyword.get(output, :bidirectional, true),
      reconnect: Keyword.get(output, :reconnect, true),
      reconnect_interval: Keyword.get(output, :reconnect_interval, 1000),
      max_reconnect_interval: Keyword.get(output, :max_reconnect_interval, 60_000),
      max_reconnect_attempts: parse_max_attempts(Keyword.get(output, :max_reconnect_attempts))
    ]
  end

  defp parse_max_attempts(nil), do: :infinity
  defp parse_max_attempts("infinity"), do: :infinity
  defp parse_max_attempts(:infinity), do: :infinity
  defp parse_max_attempts(value) when is_integer(value), do: value

  defp parse_max_attempts(value) do
    require Logger

    Logger.warning(
      "Invalid max_reconnect_attempts value: #{inspect(value)}. Expected integer or :infinity. Defaulting to :infinity."
    )

    :infinity
  end
end
