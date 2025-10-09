defmodule ElixirDnstap.BufferStage do
  @moduledoc """
  GenStage ProducerConsumer for encoding DNSTap messages.

  This stage receives dnstap message parameters from the Producer,
  encodes them into Protocol Buffers, and forwards them to the Consumer.

  ## Pipeline Position

  ```
  Producer -> BufferStage -> WriterConsumer -> Writer (Frame Streams encoding)
  ```

  ## Encoding Process

  1. Receive `{:client_query, params}` or `{:client_response, params}`
  2. Encode to Protocol Buffers using `ElixirDnstap.Encoder`
  3. Forward Protocol Buffers message to Consumer

  ## Design Note

  Frame Streams encoding is delegated to the Writer (e.g., FileWriter)
  to reuse existing Writer infrastructure and avoid double encoding.

  ## Performance

  - Processes events in batches for efficiency
  - Stateless transformation (no queueing)
  - Minimal memory overhead

  ## Usage

      # Start the buffer stage
      {:ok, buffer} = GenStage.start_link(BufferStage, [])

      # Subscribe to a producer
      GenStage.sync_subscribe(buffer, to: producer)
  """

  use GenStage
  require Logger

  alias ElixirDnstap.Encoder

  ## Client API

  @doc """
  Start the BufferStage as a GenStage process.

  ## Options

  - `:name` - Process name for registration
  - `:subscribe_to` - List of producers to subscribe to

  ## Returns

  - `{:ok, pid}` - BufferStage started successfully
  - `{:error, reason}` - Failed to start
  """
  @spec start_link(keyword()) :: GenStage.on_start()
  def start_link(opts \\ []) do
    {gen_stage_opts, init_opts} = Keyword.split(opts, [:name])
    GenStage.start_link(__MODULE__, init_opts, gen_stage_opts)
  end

  ## GenStage Callbacks

  @impl true
  def init(opts) do
    # BufferStage is stateless - no state needed
    subscribe_to = Keyword.get(opts, :subscribe_to, [])
    {:producer_consumer, %{}, subscribe_to: subscribe_to}
  end

  @impl true
  def handle_events(events, _from, state) do
    Logger.debug("[DNSTap.BufferStage] Received #{length(events)} events from Producer")

    # Encode all events to Frame Streams data frames
    encoded_frames =
      events
      |> Enum.map(&encode_event/1)
      |> Enum.reject(&is_nil/1)

    Logger.debug(
      "[DNSTap.BufferStage] Forwarding #{length(encoded_frames)} encoded frames to WriterConsumer"
    )

    {:noreply, encoded_frames, state}
  end

  ## Private Functions

  # Encode a single event to Protocol Buffers
  @spec encode_event({:client_query, map()} | {:client_response, map()}) :: binary() | nil
  defp encode_event({:client_query, params}) do
    Encoder.encode_client_query(
      params.packet,
      params.client_addr,
      params.client_port,
      params.server_addr,
      params.server_port,
      params.socket_protocol
    )
  end

  defp encode_event({:client_response, params}) do
    Encoder.encode_client_response(
      query_packet: params.query_packet,
      response_packet: params.response_packet,
      client_addr: params.client_addr,
      client_port: params.client_port,
      server_addr: params.server_addr,
      server_port: params.server_port,
      socket_protocol: params.socket_protocol,
      query_time_sec: params.query_time_sec,
      query_time_nsec: params.query_time_nsec
    )
  end

  # Skip unknown event types
  defp encode_event(_unknown), do: nil
end
