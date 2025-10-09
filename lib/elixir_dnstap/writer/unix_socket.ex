defmodule ElixirDnstap.UnixSocketWriter do
  @moduledoc """
  Frame Streams Unix socket writer for dnstap with automatic reconnection.

  This module implements the `ElixirDnstap.WriterBehaviour` for Unix domain socket
  output using the Frame Streams protocol (bi-directional stream).

  ## Features

  - GenServer-based implementation for automatic reconnection
  - Exponential backoff algorithm for reconnection attempts
  - Connection state management (connected/disconnected/reconnecting)
  - Configurable reconnection parameters
  - Frame length validation (256 KB limit) to prevent DoS attacks
  - Asynchronous connection establishment for non-blocking startup

  ## Important Notes

  **Asynchronous Connection**: The GenServer starts immediately but connection establishment
  happens asynchronously in the background. Write operations before the connection is established
  will return `{:error, {:not_connected, status}}`. The writer will automatically reconnect
  if the socket becomes available.

  **Frame Size Limits**: Both inbound and outbound frames are limited to 256 KB to prevent
  denial-of-service attacks and excessive memory usage. Messages exceeding this limit will
  be rejected with `{:error, {:frame_too_large, size, max_size}}`.

  ## Protocol Flow

  ### Handshake (Bi-directional)
  1. **READY** - Client sends with content type "protobuf:dnstap.Dnstap"
  2. **ACCEPT** - Server responds with matching content type
  3. **START** - Client sends with content type

  ### Data Exchange
  4. **DATA** - Client sends dnstap messages

  ### Shutdown
  5. **FINISH** - Client sends to terminate stream

  ## Usage

      # Start writer and connect (starts GenServer)
      {:ok, pid} = UnixSocketWriter.start(path: "/var/run/dnstap.sock")

      # Write messages
      :ok = UnixSocketWriter.write(pid, encoded_dnstap_message)

      # Close connection
      :ok = UnixSocketWriter.close(pid)

  ## Configuration

  - `:path` - Unix socket path (required)
  - `:timeout` - Connection timeout in milliseconds (default: 5000)
  - `:reconnect` - Enable automatic reconnection (default: true)
  - `:reconnect_interval` - Initial reconnection interval in ms (default: 1000)
  - `:max_reconnect_interval` - Maximum reconnection interval in ms (default: 60000)
  - `:max_reconnect_attempts` - Maximum reconnection attempts (default: :infinity)
  """

  use GenServer
  @behaviour ElixirDnstap.WriterBehaviour

  require Logger
  alias ElixirDnstap.{Config, FrameStreams}

  @content_type "protobuf:dnstap.Dnstap"
  @default_timeout 5000
  @default_reconnect_interval 1000
  @default_max_reconnect_interval 60_000
  # Maximum frame length for both inbound and outbound frames (256 KB)
  # Prevents DoS attacks and excessive memory usage
  @max_frame_length 262_144

  defmodule State do
    @moduledoc false
    @type status :: :connected | :disconnected | :reconnecting

    # Default values matching parent module's configuration
    @default_reconnect_interval 1000
    @default_max_reconnect_interval 60_000

    @type t :: %__MODULE__{
            path: String.t(),
            timeout: integer(),
            socket: :gen_tcp.socket() | nil,
            status: status(),
            reconnect_enabled: boolean(),
            reconnect_interval: integer(),
            max_reconnect_interval: integer(),
            max_reconnect_attempts: :infinity | pos_integer(),
            reconnect_attempts: non_neg_integer(),
            current_interval: integer(),
            reconnect_timer: reference() | nil
          }

    defstruct [
      :path,
      :timeout,
      :socket,
      status: :disconnected,
      reconnect_enabled: true,
      reconnect_interval: @default_reconnect_interval,
      max_reconnect_interval: @default_max_reconnect_interval,
      max_reconnect_attempts: :infinity,
      reconnect_attempts: 0,
      current_interval: @default_reconnect_interval,
      reconnect_timer: nil
    ]
  end

  # GenServer callbacks

  @impl GenServer
  def init(config) do
    reconnect_interval =
      Config.get_config_value(config, :reconnect_interval, @default_reconnect_interval)

    state = %State{
      path: Config.get_config_value(config, :path),
      timeout: Config.get_config_value(config, :timeout, @default_timeout),
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
  Starts the UnixSocketWriter GenServer as part of a supervision tree.

  This function is called by supervisors and registers the process with the module name (`__MODULE__`).

  **Note**: Connection establishment is asynchronous. The GenServer starts immediately but attempts
  to connect in the background. Write operations issued before the connection is established will
  return `{:error, {:not_connected, status}}`. For production use under supervision, this is the
  intended behavior - the writer will automatically reconnect if the socket becomes available.

  ## Parameters

  - `config` - Configuration keyword list or map with:
    - `:path` - Unix socket path (required)
    - `:timeout` - Connection timeout in ms (default: 5000)
    - `:reconnect` - Enable auto-reconnection (default: true)
    - `:reconnect_interval` - Initial retry interval in ms (default: 1000)
    - `:max_reconnect_interval` - Max retry interval in ms (default: 60000)
    - `:max_reconnect_attempts` - Max retry attempts (default: :infinity)

  ## Returns

  - `{:ok, pid}` - GenServer started successfully
  - `{:error, reason}` - Failed to start GenServer

  ## Examples

      # Access the supervised UnixSocketWriter
      case Process.whereis(ElixirDnstap.UnixSocketWriter) do
        nil -> {:error, :not_found}
        pid -> UnixSocketWriter.write(pid, message)
      end
  """
  @spec start_link(keyword() | map()) :: {:ok, pid()} | {:error, any()}
  def start_link(config) do
    path = Config.get_config_value(config, :path)

    if path == nil do
      {:error, :path_required}
    else
      GenServer.start_link(__MODULE__, config, name: __MODULE__)
    end
  end

  @impl ElixirDnstap.WriterBehaviour
  @spec start(keyword() | map()) :: {:ok, pid()} | {:error, any()}
  def start(config) do
    # For standalone usage (not under supervisor), start without name registration
    path = Config.get_config_value(config, :path)

    if path == nil do
      {:error, :path_required}
    else
      GenServer.start_link(__MODULE__, config)
    end
  end

  @doc """
  Write a dnstap message to the Unix socket (named GenServer).

  The message is automatically wrapped in a Frame Streams data frame.
  This function uses the registered process name to call the supervised UnixSocketWriter.

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
  Write a dnstap message to the Unix socket (explicit PID).

  The message is automatically wrapped in a Frame Streams data frame.

  ## Parameters

  - `pid` - UnixSocketWriter GenServer PID
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
  Close the Unix socket writer.

  Sends the FINISH control frame and stops the GenServer.

  ## Parameters

  - `pid` - UnixSocketWriter GenServer PID

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
    # Validate outbound message size
    case validate_frame_length(byte_size(message)) do
      :ok ->
        data_frame = FrameStreams.encode_data_frame(message)

        case :gen_tcp.send(socket, data_frame) do
          :ok ->
            {:reply, :ok, state}

          {:error, reason} ->
            Logger.error("Failed to write to Unix socket: #{inspect(reason)}")
            # Trigger reconnection
            new_state = handle_disconnect(state)
            {:reply, {:error, reason}, new_state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:write, _message}, _from, %State{status: status} = state) do
    {:reply, {:error, {:not_connected, status}}, state}
  end

  @impl GenServer
  def handle_info(:connect, state) do
    case do_connect(state) do
      {:ok, socket} ->
        Logger.info("DNSTap UnixSocketWriter connected: #{state.path}")

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
        Logger.warning("Failed to connect to Unix socket #{state.path}: #{inspect(reason)}")

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

  # Handle incoming data on current socket (protocol violation - Frame Streams protocol uses active: false)
  def handle_info({:tcp, socket, data}, %State{socket: socket} = state) do
    Logger.warning(
      "Unexpected data received on #{state.path}: #{byte_size(data)} bytes. " <>
        "Frame Streams protocol should use passive mode for data reception."
    )

    # This is a protocol violation - close connection and trigger reconnection
    new_state = handle_disconnect(state)
    {:noreply, new_state}
  end

  # Handle incoming data from old/closed socket (ignore stale messages)
  def handle_info({:tcp, _old_socket, _data}, state) do
    # Ignore messages from old sockets after reconnection
    {:noreply, state}
  end

  def handle_info({:tcp_closed, socket}, %State{socket: socket} = state) do
    Logger.warning("Unix socket connection closed: #{state.path}")
    new_state = handle_disconnect(state)
    {:noreply, new_state}
  end

  def handle_info({:tcp_error, socket, reason}, %State{socket: socket} = state) do
    Logger.error("Unix socket error on #{state.path}: #{inspect(reason)}")
    new_state = handle_disconnect(state)
    {:noreply, new_state}
  end

  @impl GenServer
  def terminate(_reason, %State{socket: nil}), do: :ok

  def terminate(_reason, %State{socket: socket, path: path}) do
    # Send FINISH frame
    finish_frame = FrameStreams.encode_control_frame(:finish, nil)

    case :gen_tcp.send(socket, finish_frame) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to send FINISH frame to #{path}: #{inspect(reason)}")
    end

    # Close socket
    :gen_tcp.close(socket)
    Logger.info("DNSTap UnixSocketWriter closed: #{path}")

    :ok
  end

  # Private functions

  defp do_connect(%State{path: path, timeout: timeout}) do
    socket_address = {:local, String.to_charlist(path)}

    # Port is set to 0 for Unix domain sockets; it is ignored in this context
    with {:ok, socket} <-
           :gen_tcp.connect(
             socket_address,
             0,
             [:binary, {:active, false}, {:packet, 0}],
             timeout
           ),
         :ok <- perform_handshake(socket, timeout) do
      {:ok, socket}
    else
      {:error, {:handshake_failed, reason}} ->
        {:error, {:handshake_failed, reason}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp perform_handshake(socket, timeout) do
    with :ok <- send_ready(socket),
         :ok <- receive_accept(socket, timeout),
         :ok <- send_start(socket) do
      :ok
    else
      {:error, reason} ->
        # Close socket on handshake failure to prevent resource leak
        :gen_tcp.close(socket)
        {:error, {:handshake_failed, reason}}
    end
  end

  defp send_ready(socket) do
    ready_frame = FrameStreams.encode_control_frame(:ready, @content_type)

    case :gen_tcp.send(socket, ready_frame) do
      :ok -> :ok
      {:error, reason} -> {:error, {:send_ready_failed, reason}}
    end
  end

  defp receive_accept(socket, timeout) do
    case receive_control_frame(socket, timeout) do
      {:ok, {:control, :accept, @content_type}} ->
        :ok

      {:ok, {:control, type, content_type}} ->
        {:error, {:unexpected_control_frame, type, content_type}}

      {:error, reason} ->
        {:error, {:receive_accept_failed, reason}}
    end
  end

  defp send_start(socket) do
    start_frame = FrameStreams.encode_control_frame(:start, @content_type)

    case :gen_tcp.send(socket, start_frame) do
      :ok -> :ok
      {:error, reason} -> {:error, {:send_start_failed, reason}}
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
    # Read length field (4 bytes)
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
    Logger.error("Maximum reconnection attempts (#{max_attempts}) reached for #{state.path}")

    %State{state | status: :disconnected}
  end

  defp schedule_reconnect(state) do
    # Cancel existing timer if present and flush any pending :reconnect messages
    if state.reconnect_timer do
      case Process.cancel_timer(state.reconnect_timer) do
        false ->
          # Timer had already fired, flush the message from mailbox
          receive do
            :reconnect -> :ok
          after
            0 -> :ok
          end

        _remaining_time ->
          # Timer was cancelled before firing
          :ok
      end
    end

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
