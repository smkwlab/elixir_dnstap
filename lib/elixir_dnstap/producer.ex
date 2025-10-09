defmodule ElixirDnstap.Producer do
  @moduledoc """
  GenStage Producer for DNSTap messages.

  This module receives dnstap messages from DNSWorker via `GenStage.cast/2`
  and produces events for downstream consumers with backpressure control.

  ## Message Types

  - `{:client_query, params}` - CLIENT_QUERY message parameters
  - `{:client_response, params}` - CLIENT_RESPONSE message parameters

  ## Backpressure Control

  The producer implements demand-based backpressure:
  - Messages are queued when no demand is available
  - Messages are dispatched immediately when demand exists
  - `max_demand` prevents unbounded demand accumulation

  ## Usage

      # Start the producer
      {:ok, producer} = GenStage.start_link(Producer, max_demand: 100)

      # Send a message from DNSWorker
      GenStage.cast(producer, {:client_query, params})

      # Messages will be dispatched to consumers based on demand
  """

  use GenStage
  require Logger

  defstruct queue: :queue.new(),
            demand: 0,
            max_demand: 100

  @type t :: %__MODULE__{
          queue: :queue.queue(),
          demand: non_neg_integer(),
          max_demand: pos_integer()
        }

  @type message_type :: :client_query | :client_response
  @type message :: {message_type(), map()}

  ## Client API

  @doc """
  Start the Producer as a GenStage process.

  ## Options

  - `:max_demand` - Maximum demand to accumulate (default: 100)
  - `:name` - Process name for registration

  ## Returns

  - `{:ok, pid}` - Producer started successfully
  - `{:error, reason}` - Failed to start
  """
  @spec start_link(keyword()) :: GenStage.on_start()
  def start_link(opts \\ []) do
    {gen_stage_opts, init_opts} = Keyword.split(opts, [:name])
    GenStage.start_link(__MODULE__, init_opts, gen_stage_opts)
  end

  @doc """
  Send a dnstap message to the producer.

  This function is called by DNSWorker to enqueue messages for processing.

  ## Parameters

  - `message` - `{:client_query, params}` or `{:client_response, params}`

  ## Examples

      GenStage.cast(producer, {:client_query, query_params})
      GenStage.cast(producer, {:client_response, response_params})
  """
  @spec enqueue(GenServer.server(), message()) :: :ok
  def enqueue(producer, message) do
    GenStage.cast(producer, message)
  end

  ## GenStage Callbacks

  @impl true
  def init(opts) do
    max_demand = Keyword.get(opts, :max_demand, 100)

    state = %__MODULE__{
      queue: :queue.new(),
      demand: 0,
      max_demand: max_demand
    }

    {:producer, state}
  end

  @impl true
  def handle_cast(message, state) when is_tuple(message) do
    Logger.debug(
      "[DNSTap.Producer] Received message: #{inspect(elem(message, 0))}, current demand: #{state.demand}, queue size: #{:queue.len(state.queue)}"
    )

    dispatch_events(:queue.in(message, state.queue), state.demand, [], state.max_demand)
  end

  @impl true
  def handle_demand(incoming_demand, state) do
    # Cap total demand at max_demand to prevent unbounded accumulation
    new_demand = min(state.demand + incoming_demand, state.max_demand)

    Logger.debug(
      "[DNSTap.Producer] Demand received: #{incoming_demand}, new total demand: #{new_demand}, queue size: #{:queue.len(state.queue)}"
    )

    dispatch_events(state.queue, new_demand, [], state.max_demand)
  end

  ## Private Functions

  # Dispatch queued events based on available demand
  @spec dispatch_events(:queue.queue(), non_neg_integer(), [message()], pos_integer()) ::
          {:noreply, [message()], t()}
  defp dispatch_events(queue, demand, events, max_demand) do
    case {demand, :queue.out(queue)} do
      # No demand left - stop dispatching
      {0, _} ->
        {:noreply, Enum.reverse(events),
         %__MODULE__{queue: queue, demand: 0, max_demand: max_demand}}

      # Queue empty - accumulate demand
      {demand, {:empty, queue}} ->
        {:noreply, Enum.reverse(events),
         %__MODULE__{queue: queue, demand: demand, max_demand: max_demand}}

      # Dispatch one event and continue
      {demand, {{:value, event}, queue}} ->
        dispatch_events(queue, demand - 1, [event | events], max_demand)
    end
  end
end
