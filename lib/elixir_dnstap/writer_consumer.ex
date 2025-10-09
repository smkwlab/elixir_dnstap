defmodule ElixirDnstap.WriterConsumer do
  @moduledoc """
  GenStage Consumer for writing DNSTap Frame Streams data to output.

  This consumer receives encoded Frame Streams data frames from BufferStage
  and writes them directly to a file.

  ## Pipeline Position

  ```
  Producer -> BufferStage -> WriterConsumer
  ```

  ## Responsibilities

  1. Receive encoded Frame Streams data frames from BufferStage
  2. Write frames directly to file (raw binary I/O)
  3. Handle write errors gracefully with logging
  4. Process frames in batches for efficiency

  ## Design Note

  WriterConsumer performs direct file I/O instead of using FileWriter GenServer.
  This is because BufferStage already encodes frames in Frame Streams format,
  so no additional encoding is needed - just raw binary writes.

  ## Usage

      # Start the writer consumer
      {:ok, consumer} = GenStage.start_link(
        WriterConsumer,
        writer_module: ElixirDnstap.FileWriter
      )

      # Subscribe to a producer/consumer
      GenStage.sync_subscribe(consumer, to: buffer_stage)
  """

  use GenStage

  require Logger

  defstruct writer_module: nil,
            file: nil

  @type t :: %__MODULE__{
          writer_module: module()
        }

  ## Client API

  @doc """
  Start the WriterConsumer as a GenStage process.

  ## Options

  - `:writer_module` - Writer module to use (required)
  - `:subscribe_to` - List of producer_consumers to subscribe to
  - `:name` - Process name for registration

  ## Returns

  - `{:ok, pid}` - WriterConsumer started successfully
  - `{:error, reason}` - Failed to start
  """
  @spec start_link(keyword()) :: GenStage.on_start()
  def start_link(opts) do
    {gen_stage_opts, init_opts} = Keyword.split(opts, [:name])
    GenStage.start_link(__MODULE__, init_opts, gen_stage_opts)
  end

  ## GenStage Callbacks

  @impl true
  def init(opts) do
    writer_module = Keyword.fetch!(opts, :writer_module)
    subscribe_to = Keyword.get(opts, :subscribe_to, [])

    state = %__MODULE__{
      writer_module: writer_module
    }

    {:consumer, state, subscribe_to: subscribe_to}
  end

  @impl true
  def handle_events(events, _from, state) do
    Logger.debug("[DNSTap.WriterConsumer] Received #{length(events)} frames from BufferStage")

    # Write all frames to the writer
    Enum.each(events, fn frame ->
      write_frame(frame, state.writer_module)
    end)

    Logger.debug("[DNSTap.WriterConsumer] Finished writing #{length(events)} frames")
    {:noreply, [], state}
  end

  ## Private Functions

  # Write a single frame to the writer
  @spec write_frame(binary(), module()) :: :ok
  defp write_frame(frame, writer_module) when is_binary(frame) do
    Logger.debug(
      "[DNSTap.WriterConsumer] Calling #{inspect(writer_module)}.write with #{byte_size(frame)} bytes"
    )

    case writer_module.write(frame) do
      :ok ->
        Logger.debug("[DNSTap.WriterConsumer] Write successful")
        :ok

      {:error, reason} ->
        Logger.warning("WriterConsumer write failed: #{inspect(reason)}")
        :ok
    end
  rescue
    e ->
      error_msg = Exception.message(e)
      Logger.warning("WriterConsumer write exception: #{error_msg}")
      :ok
  end

  # Skip non-binary frames
  defp write_frame(_non_binary, _writer_module), do: :ok
end
