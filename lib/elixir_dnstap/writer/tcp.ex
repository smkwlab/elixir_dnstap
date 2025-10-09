defmodule ElixirDnstap.TcpWriter do
  @moduledoc """
  Frame Streams TCP writer for dnstap with automatic reconnection.

  This module implements the `ElixirDnstap.WriterBehaviour` for TCP socket
  output using the Frame Streams protocol (bi-directional or uni-directional stream).

  ## Features

  - GenServer-based implementation for automatic reconnection
  - Exponential backoff algorithm for reconnection attempts
  - Connection state management (connected/disconnected/reconnecting)
  - Configurable reconnection parameters
  - Support for both bi-directional and uni-directional Frame Streams protocols

  ## Protocol Flow

  ### Bi-directional Mode (default)
  1. **READY** - Client sends with content type "protobuf:dnstap.Dnstap"
  2. **ACCEPT** - Server responds with matching content type
  3. **START** - Client sends with content type
  4. **DATA** - Client sends dnstap messages
  5. **FINISH** - Client sends to terminate stream

  ### Uni-directional Mode
  1. **START** - Client sends with content type
  2. **DATA** - Client sends dnstap messages
  3. **STOP** - Client sends to terminate stream

  Note: Use uni-directional mode for receivers that don't support bi-directional
  protocol (e.g., `dnstap -l` command).

  ## Usage

  ### Direct Usage (for testing or custom integration)

      # Start writer and connect (starts GenServer)
      {:ok, pid} = TcpWriter.start(host: "localhost", port: 5555)

      # Write messages
      :ok = TcpWriter.write(pid, encoded_dnstap_message)

      # Close connection
      :ok = TcpWriter.close(pid)

  ### Production Usage (via WriterManager and YAML configuration)

  In production, TcpWriter is automatically started by `ElixirDnstap.WriterManager`
  when DNSTap is configured with TCP output in `priv/tenbin_cache.yaml`:

      dnstap:
        enabled: true
        output:
          type: tcp
          host: "dnstap-collector.example.com"
          port: 6000
          bidirectional: false  # Use uni-directional mode for dnstap -l
          reconnect: true
          reconnect_interval: 1000
          max_reconnect_attempts: 10

  The WriterManager supervises the TcpWriter process and handles lifecycle management.
  DNS workers automatically send dnstap messages through the configured writer.

  ## Configuration

  - `:host` - Remote host (String.t(), required)
  - `:port` - Remote port (integer(), required)
  - `:timeout` - Connection timeout in milliseconds (default: 5000)
  - `:bidirectional` - Use bi-directional Frame Streams protocol (default: true)
  - `:reconnect` - Enable automatic reconnection (default: true)
  - `:reconnect_interval` - Initial reconnection interval in ms (default: 1000)
  - `:max_reconnect_interval` - Maximum reconnection interval in ms (default: 60000)
  - `:max_reconnect_attempts` - Maximum reconnection attempts (default: :infinity)

  ## Reconnection Behavior

  When `reconnect: true`, the TcpWriter uses exponential backoff to automatically
  reconnect on connection failures:

  1. Initial connection attempt fails
  2. Wait `reconnect_interval` ms (default: 1000ms)
  3. Retry connection
  4. If failed, double the interval (exponential backoff)
  5. Continue doubling until `max_reconnect_interval` is reached (default: 60000ms),
     then use the capped interval for all subsequent retries (i.e., do not continue doubling)
  6. Repeat until `max_reconnect_attempts` is exhausted or connection succeeds

  During reconnection, `write/2` returns `{:error, {:not_connected, status}}` but
  the GenServer continues running and attempting to reconnect in the background.
  """

  use GenServer
  @behaviour ElixirDnstap.WriterBehaviour

  require Logger
  alias ElixirDnstap.{Config, FrameStreams}

  @content_type "protobuf:dnstap.Dnstap"
  @default_timeout 5000
  @default_reconnect_interval 1000
  @default_max_reconnect_interval 60_000
  # Maximum frame length to prevent DoS attacks (256 KB)
  @max_frame_length 262_144

  defmodule State do
    @moduledoc false
    @type status :: :connected | :disconnected | :reconnecting

    @type t :: %__MODULE__{
            host: String.t(),
            port: integer(),
            timeout: integer(),
            socket: :gen_tcp.socket() | nil,
            status: status(),
            bidirectional: boolean(),
            reconnect_enabled: boolean(),
            reconnect_interval: integer(),
            max_reconnect_interval: integer(),
            max_reconnect_attempts: :infinity | pos_integer(),
            reconnect_attempts: non_neg_integer(),
            current_interval: integer(),
            reconnect_timer: reference() | nil
          }

    defstruct [
      :host,
      :port,
      :timeout,
      :socket,
      status: :disconnected,
      bidirectional: true,
      reconnect_enabled: true,
      reconnect_interval: 1000,
      max_reconnect_interval: 60_000,
      max_reconnect_attempts: :infinity,
      reconnect_attempts: 0,
      current_interval: 1000,
      reconnect_timer: nil
    ]
  end

  # GenServer callbacks

  @impl GenServer
  def init(config) do
    reconnect_interval =
      Config.get_config_value(config, :reconnect_interval, @default_reconnect_interval)

    bidirectional = Config.get_config_value(config, :bidirectional, true)
    Logger.debug("[TcpWriter] Initializing with bidirectional mode: #{bidirectional}")

    state = %State{
      host: Config.get_config_value(config, :host),
      port: Config.get_config_value(config, :port),
      timeout: Config.get_config_value(config, :timeout, @default_timeout),
      bidirectional: bidirectional,
      reconnect_enabled: Config.get_config_value(config, :reconnect, true),
      reconnect_interval: reconnect_interval,
      max_reconnect_interval:
        Config.get_config_value(
          config,
          :max_reconnect_interval,
          @default_max_reconnect_interval
        ),
      max_reconnect_attempts: Config.get_config_value(config, :max_reconnect_attempts, :infinity),
      current_interval: reconnect_interval
    }

    # Attempt initial connection
    send(self(), :connect)

    {:ok, state}
  end

  @doc """
  Starts the TcpWriter GenServer as part of a supervision tree.

  This function is called by supervisors and registers the process with the module name (`__MODULE__`).
  Other processes can access the registered TcpWriter process using `Process.whereis(__MODULE__)` or
  by calling `write/2` and `close/1` functions which internally use the registered name.

  ## Parameters

  - `config` - Configuration keyword list or map with:
    - `:host` - Remote host (required)
    - `:port` - Remote port (required)
    - `:timeout` - Connection timeout in ms (default: 5000)
    - `:reconnect` - Enable auto-reconnection (default: true)
    - `:reconnect_interval` - Initial retry interval in ms (default: 1000)
    - `:max_reconnect_interval` - Max retry interval in ms (default: 60000)
    - `:max_reconnect_attempts` - Max retry attempts (default: :infinity)

  ## Returns

  - `{:ok, pid}` - GenServer started successfully
  - `{:error, reason}` - Failed to start GenServer

  ## Examples

      # Access the supervised TcpWriter
      case Process.whereis(ElixirDnstap.TcpWriter) do
        nil -> {:error, :not_found}
        pid -> TcpWriter.write(pid, message)
      end
  """
  @spec start_link(keyword() | map()) :: {:ok, pid()} | {:error, any()}
  def start_link(config) do
    host = Config.get_config_value(config, :host)
    port = Config.get_config_value(config, :port)

    cond do
      host == nil ->
        {:error, :host_required}

      port == nil ->
        {:error, :port_required}

      true ->
        GenServer.start_link(__MODULE__, config, name: __MODULE__)
    end
  end

  @impl ElixirDnstap.WriterBehaviour
  @spec start(keyword() | map()) :: {:ok, pid()} | {:error, any()}
  def start(config) do
    # For standalone usage (not under supervisor), start without name registration
    host = Config.get_config_value(config, :host)
    port = Config.get_config_value(config, :port)

    cond do
      host == nil ->
        {:error, :host_required}

      port == nil ->
        {:error, :port_required}

      true ->
        GenServer.start_link(__MODULE__, config)
    end
  end

  @doc """
  Write a dnstap message to the TCP socket (named GenServer).

  The message is automatically wrapped in a Frame Streams data frame.
  This function uses the registered process name to call the supervised TcpWriter.

  ## Parameters

  - `message` - Encoded dnstap Protocol Buffer message

  ## Returns

  - `:ok` - Write successful
  - `{:error, reason}` - Write failed (e.g., not connected)
  """
  @spec write(binary()) :: :ok | {:error, any()}
  def write(message) when is_binary(message) do
    GenServer.call(__MODULE__, {:write, message})
  end

  @doc """
  Write a dnstap message to the TCP socket (explicit PID).

  The message is automatically wrapped in a Frame Streams data frame.

  ## Parameters

  - `pid` - TcpWriter GenServer PID
  - `message` - Encoded dnstap Protocol Buffer message

  ## Returns

  - `:ok` - Write successful
  - `{:error, reason}` - Write failed (e.g., not connected)
  """
  @impl ElixirDnstap.WriterBehaviour
  @spec write(pid(), binary()) :: :ok | {:error, any()}
  def write(pid, message) when is_binary(message) do
    GenServer.call(pid, {:write, message})
  end

  @doc """
  Close the TCP writer.

  Sends the FINISH control frame and stops the GenServer.

  ## Parameters

  - `pid` - TcpWriter GenServer PID

  ## Returns

  - `:ok` - Close successful
  """
  @impl ElixirDnstap.WriterBehaviour
  @spec close(pid()) :: :ok
  def close(pid) do
    GenServer.stop(pid, :normal)
  end

  @impl GenServer
  def handle_call({:write, message}, _from, %State{status: :connected, socket: socket} = state) do
    Logger.debug(
      "[TcpWriter] handle_call(:write) received #{byte_size(message)} bytes, status: connected, socket: #{inspect(socket)}"
    )

    data_frame = FrameStreams.encode_data_frame(message)

    Logger.debug(
      "[TcpWriter] Encoded to Frame Streams data frame: #{byte_size(data_frame)} bytes"
    )

    case :gen_tcp.send(socket, data_frame) do
      :ok ->
        Logger.debug("[TcpWriter] :gen_tcp.send successful")
        {:reply, :ok, state}

      {:error, reason} ->
        Logger.error("Failed to write to TCP socket: #{inspect(reason)}")
        # Trigger reconnection
        new_state = handle_disconnect(state)
        {:reply, {:error, reason}, new_state}
    end
  end

  def handle_call({:write, _message}, _from, %State{status: status} = state) do
    Logger.warning(
      "[TcpWriter] handle_call(:write) called but status is #{status}, not connected"
    )

    {:reply, {:error, {:not_connected, status}}, state}
  end

  @impl GenServer
  def handle_info(:connect, state) do
    case do_connect(state) do
      {:ok, socket} ->
        Logger.info("DNSTap TcpWriter connected: #{state.host}:#{state.port}")

        new_state = %State{
          state
          | socket: socket,
            status: :connected,
            reconnect_attempts: 0,
            current_interval: state.reconnect_interval,
            reconnect_timer: nil
        }

        {:noreply, new_state}

      {:error, reason} ->
        Logger.warning(
          "Failed to connect to TCP server #{state.host}:#{state.port}: #{inspect(reason)}"
        )

        new_state = schedule_reconnect(state)
        {:noreply, new_state}
    end
  end

  def handle_info(:reconnect, state) do
    # Clear the timer reference and attempt reconnection
    new_state = %State{state | reconnect_timer: nil}
    send(self(), :connect)
    {:noreply, new_state}
  end

  # Note: With {:active, false}, we don't receive {:tcp, socket, data} messages
  # All data reception is done synchronously via :gen_tcp.recv during handshake

  def handle_info({:tcp_closed, socket}, %State{socket: socket} = state) do
    Logger.warning("TCP connection closed: #{state.host}:#{state.port}")
    new_state = handle_disconnect(state)
    {:noreply, new_state}
  end

  def handle_info({:tcp_error, socket, reason}, %State{socket: socket} = state) do
    Logger.error("TCP error on #{state.host}:#{state.port}: #{inspect(reason)}")
    new_state = handle_disconnect(state)
    {:noreply, new_state}
  end

  @impl GenServer
  def terminate(_reason, %State{socket: nil}), do: :ok

  def terminate(_reason, %State{socket: socket, host: host, port: port}) do
    # Send FINISH frame
    finish_frame = FrameStreams.encode_control_frame(:finish, nil)

    case :gen_tcp.send(socket, finish_frame) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to send FINISH frame to #{host}:#{port}: #{inspect(reason)}")
    end

    # Close socket
    :gen_tcp.close(socket)
    Logger.info("DNSTap TcpWriter closed: #{host}:#{port}")

    :ok
  end

  # Private functions

  defp do_connect(%State{host: host, port: port, timeout: timeout, bidirectional: bidirectional}) do
    # Convert host string to charlist for :gen_tcp
    host_charlist = String.to_charlist(host)

    # Connect to TCP server
    # Use {:active, false} for synchronous control during handshake and data transmission
    # (Frame Streams can be bi-directional)
    with {:ok, socket} <-
           :gen_tcp.connect(
             host_charlist,
             port,
             [
               :binary,
               {:active, false},
               {:packet, 0},
               {:keepalive, true},
               {:nodelay, true}
             ],
             timeout
           ),
         :ok <- perform_handshake(socket, timeout, bidirectional) do
      {:ok, socket}
    else
      {:error, {:handshake_failed, reason}} ->
        {:error, {:handshake_failed, reason}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Bi-directional Frame Streams handshake
  defp perform_handshake(socket, timeout, true = _bidirectional) do
    Logger.debug("[TcpWriter] Starting bi-directional Frame Streams handshake")

    with :ok <- send_ready(socket),
         :ok <- receive_accept(socket, timeout),
         :ok <- send_start(socket) do
      Logger.info("[TcpWriter] Bi-directional Frame Streams handshake completed successfully")
      :ok
    else
      {:error, reason} ->
        Logger.error(
          "[TcpWriter] Bi-directional Frame Streams handshake failed: #{inspect(reason)}"
        )

        # Close socket on handshake failure to prevent resource leak
        :gen_tcp.close(socket)
        {:error, {:handshake_failed, reason}}
    end
  end

  # Uni-directional Frame Streams handshake (skip READY/ACCEPT)
  defp perform_handshake(socket, _timeout, false = _bidirectional) do
    Logger.debug("[TcpWriter] Starting uni-directional Frame Streams handshake")

    case send_start(socket) do
      :ok ->
        Logger.info("[TcpWriter] Uni-directional Frame Streams handshake completed successfully")
        :ok

      {:error, reason} ->
        Logger.error(
          "[TcpWriter] Uni-directional Frame Streams handshake failed: #{inspect(reason)}"
        )

        # Close socket on handshake failure to prevent resource leak
        :gen_tcp.close(socket)
        {:error, {:handshake_failed, reason}}
    end
  end

  defp send_ready(socket) do
    ready_frame = FrameStreams.encode_control_frame(:ready, @content_type)
    Logger.debug("[TcpWriter] Sending READY frame (#{byte_size(ready_frame)} bytes)")

    case :gen_tcp.send(socket, ready_frame) do
      :ok ->
        Logger.debug("[TcpWriter] READY frame sent successfully")
        :ok

      {:error, reason} ->
        Logger.error("[TcpWriter] Failed to send READY frame: #{inspect(reason)}")
        {:error, {:send_ready_failed, reason}}
    end
  end

  defp receive_accept(socket, timeout) do
    Logger.debug("[TcpWriter] Waiting for ACCEPT frame (timeout: #{timeout}ms)")

    case receive_control_frame(socket, timeout) do
      {:ok, {:control, :accept, @content_type}} ->
        Logger.debug("[TcpWriter] ACCEPT frame received with correct content type")
        :ok

      {:ok, {:control, type, content_type}} ->
        Logger.error(
          "[TcpWriter] Unexpected control frame: type=#{type}, content_type=#{content_type}"
        )

        {:error, {:unexpected_control_frame, type, content_type}}

      {:error, reason} ->
        Logger.error("[TcpWriter] Failed to receive ACCEPT frame: #{inspect(reason)}")
        {:error, {:receive_accept_failed, reason}}
    end
  end

  defp send_start(socket) do
    start_frame = FrameStreams.encode_control_frame(:start, @content_type)
    Logger.debug("[TcpWriter] Sending START frame (#{byte_size(start_frame)} bytes)")

    case :gen_tcp.send(socket, start_frame) do
      :ok ->
        Logger.debug("[TcpWriter] START frame sent successfully")
        :ok

      {:error, reason} ->
        Logger.error("[TcpWriter] Failed to send START frame: #{inspect(reason)}")
        {:error, {:send_start_failed, reason}}
    end
  end

  defp receive_control_frame(socket, timeout) do
    with {:ok, frame} <- receive_frame(socket, timeout),
         {:ok, decoded, <<>>} <- FrameStreams.decode_frame(frame) do
      {:ok, decoded}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp receive_frame(socket, timeout) do
    # Socket is in passive mode ({:active, false}) to allow synchronous frame reception
    # during the Frame Streams handshake.
    case :gen_tcp.recv(socket, 4, timeout) do
      {:ok, <<0::32-big>>} ->
        read_control_frame(socket, timeout)

      {:ok, <<length::32-big>>} ->
        read_data_frame(socket, length, timeout)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp read_control_frame(socket, timeout) do
    # Control frame - read control length and payload
    with {:ok, <<control_length::32-big>>} <- :gen_tcp.recv(socket, 4, timeout),
         :ok <- validate_frame_length(control_length),
         {:ok, control_payload} <- :gen_tcp.recv(socket, control_length, timeout) do
      {:ok, <<0::32-big, control_length::32-big, control_payload::binary>>}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_data_frame(socket, length, timeout) do
    # Data frame - read payload
    with :ok <- validate_frame_length(length),
         {:ok, payload} <- :gen_tcp.recv(socket, length, timeout) do
      {:ok, <<length::32-big, payload::binary>>}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_frame_length(length) when length > @max_frame_length do
    {:error, {:frame_too_large, length, @max_frame_length}}
  end

  defp validate_frame_length(_length), do: :ok

  defp handle_disconnect(%State{socket: socket} = state) when socket != nil do
    :gen_tcp.close(socket)
    new_state = %State{state | socket: nil, status: :disconnected}
    schedule_reconnect(new_state)
  end

  defp handle_disconnect(state) do
    new_state = %State{state | status: :disconnected}
    schedule_reconnect(new_state)
  end

  defp schedule_reconnect(%State{reconnect_enabled: false} = state) do
    Logger.info("Reconnection disabled, staying disconnected")
    state
  end

  defp schedule_reconnect(
         %State{
           reconnect_attempts: attempts,
           max_reconnect_attempts: max_attempts
         } = state
       )
       when is_integer(max_attempts) and attempts >= max_attempts do
    Logger.error(
      "Maximum reconnection attempts (#{max_attempts}) reached for #{state.host}:#{state.port}"
    )

    %State{state | status: :disconnected}
  end

  defp schedule_reconnect(state) do
    interval = state.current_interval
    timer_ref = Process.send_after(self(), :reconnect, interval)

    # Calculate next interval with exponential backoff
    next_interval = min(interval * 2, state.max_reconnect_interval)

    Logger.info(
      "Scheduling reconnection attempt ##{state.reconnect_attempts + 1} in #{interval}ms"
    )

    %State{
      state
      | status: :reconnecting,
        reconnect_attempts: state.reconnect_attempts + 1,
        current_interval: next_interval,
        reconnect_timer: timer_ref
    }
  end
end
