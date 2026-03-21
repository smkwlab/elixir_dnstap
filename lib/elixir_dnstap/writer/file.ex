defmodule ElixirDnstap.Writer.File do
  @moduledoc """
  Frame Streams file writer for dnstap (GenServer implementation).

  This module implements a GenServer-based file writer for DNSTap messages
  using the Frame Streams protocol (uni-directional stream).

  ## Protocol Flow

  1. **START** - Written on GenServer init with content type "protobuf:dnstap.Dnstap"
  2. **DATA** - Written for each dnstap message (appended to file)
  3. **STOP** - Written on GenServer termination

  ## GenServer Lifecycle

  The Writer.File runs as a named GenServer under the ElixirDnstap.Supervisor supervision tree:

  - **Initialization**: Opens file and writes START frame
  - **Runtime**: Handles write requests and appends DATA frames
  - **Termination**: Writes STOP frame and closes file

  ## Usage

      # Start writer (supervised)
      {:ok, _pid} = ElixirDnstap.Writer.File.start_link(path: "/var/log/tenbin_cache/dnstap.fstrm")

      # Write messages (via named process)
      :ok = ElixirDnstap.Writer.File.write(encoded_dnstap_message)

      # GenServer automatically handles STOP frame on termination

  ## Configuration

  - `:path` - File path for output (required)
  """

  use GenServer
  require Logger
  alias ElixirDnstap.{Config, FrameStreams}

  @content_type "protobuf:dnstap.Dnstap"

  @type t :: %__MODULE__{
          file: File.io_device(),
          path: String.t()
        }

  defstruct [:file, :path]

  ## GenServer API

  @doc """
  Start the Writer.File GenServer.

  This function is called by ElixirDnstap.Supervisor.

  ## Parameters

  - `config` - Configuration keyword list or map with `:path` key

  ## Returns

  - `{:ok, pid}` - GenServer started successfully
  - `{:error, reason}` - Failed to start GenServer
  """
  @spec start_link(keyword() | map()) :: GenServer.on_start()
  def start_link(config) do
    GenServer.start_link(__MODULE__, config, name: __MODULE__)
  end

  @doc """
  Write a dnstap message to the file.

  The message is automatically wrapped in a Frame Streams data frame.

  ## Parameters

  - `message` - Encoded dnstap Protocol Buffer message

  ## Returns

  - `:ok` - Write successful
  - `{:error, reason}` - Write failed
  """
  @spec write(binary()) :: :ok | {:error, any()}
  def write(message) when is_binary(message) do
    GenServer.call(__MODULE__, {:write, message})
  end

  ## GenServer Callbacks

  @impl true
  def init(config) do
    path = Config.get_config_value(config, :path)

    if path == nil do
      {:stop, {:error, :path_required}}
    else
      case do_init(path) do
        {:ok, state} ->
          {:ok, state}

        {:error, reason} ->
          {:stop, {:error, reason}}
      end
    end
  end

  @impl true
  def handle_call({:write, message}, _from, %__MODULE__{file: file} = state) do
    data_frame = FrameStreams.encode_data_frame(message)
    IO.binwrite(file, data_frame)
    {:reply, :ok, state}
  rescue
    e ->
      error_msg = Exception.message(e)
      Logger.warning("Writer.File write failed: #{error_msg}")
      {:reply, {:error, error_msg}, state}
  end

  @impl true
  def terminate(_reason, %__MODULE__{file: file, path: path}) do
    # Safely write STOP frame and close file
    try do
      stop_frame = FrameStreams.encode_control_frame(:stop, nil)
      IO.binwrite(file, stop_frame)
      File.close(file)
      Logger.info("DNSTap Writer.File closed: #{path}")
    rescue
      e ->
        Logger.warning("Error closing Writer.File #{path}: #{inspect(e)}")
    end

    :ok
  end

  ## Private functions

  defp do_init(path) do
    # Ensure parent directory exists
    case path |> Path.dirname() |> File.mkdir_p() do
      :ok ->
        open_file_and_write_start(path)

      {:error, reason} ->
        Logger.error("Failed to create directory for dnstap file #{path}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp open_file_and_write_start(path) do
    case File.open(path, [:write, :binary]) do
      {:ok, file} ->
        # Write START control frame
        start_frame = FrameStreams.encode_control_frame(:start, @content_type)
        IO.binwrite(file, start_frame)

        state = %__MODULE__{
          file: file,
          path: path
        }

        Logger.info("DNSTap Writer.File initialized: #{path}")
        {:ok, state}

      {:error, reason} ->
        Logger.error("Failed to open dnstap file #{path}: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
