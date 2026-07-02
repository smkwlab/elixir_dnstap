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

  `GenStage.cast/2` is fire-and-forget, so a slow or disconnected downstream
  writer cannot back-pressure the caller. To bound memory, the internal queue
  has a `max_queue_size` high-water mark: once it is full, further messages are
  **dropped** (tail drop) with a throttled counter/log rather than growing the
  queue without limit. DNSTap is observability data, so dropping under overload
  is preferable to OOMing the host.

  ## Usage

      # Start the producer
      {:ok, producer} = GenStage.start_link(Producer, max_demand: 100)

      # Send a message from DNSWorker
      GenStage.cast(producer, {:client_query, params})

      # Messages will be dispatched to consumers based on demand
  """

  use GenStage
  require Logger

  # Default high-water mark for the internal queue.
  @default_max_queue_size 10_000

  # Emit at most one "dropped" warning per this many drops.
  @drop_log_interval 1_000

  defstruct queue: :queue.new(),
            queue_len: 0,
            demand: 0,
            max_demand: 100,
            max_queue_size: @default_max_queue_size,
            dropped: 0

  @type t :: %__MODULE__{
          queue: :queue.queue(),
          queue_len: non_neg_integer(),
          demand: non_neg_integer(),
          max_demand: pos_integer(),
          max_queue_size: pos_integer(),
          dropped: non_neg_integer()
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
  @spec start_link(keyword()) :: GenServer.on_start()
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

    max_queue_size =
      valid_max_queue_size(Keyword.get(opts, :max_queue_size, @default_max_queue_size))

    state = %__MODULE__{
      queue: :queue.new(),
      queue_len: 0,
      demand: 0,
      max_demand: max_demand,
      max_queue_size: max_queue_size,
      dropped: 0
    }

    {:producer, state}
  end

  # A non-integer or non-positive max_queue_size would make the cap meaningless
  # (e.g. `queue_len >= 0` drops everything), so fall back to the default.
  defp valid_max_queue_size(size) when is_integer(size) and size > 0, do: size

  defp valid_max_queue_size(invalid) do
    Logger.warning(
      "[DNSTap.Producer] invalid max_queue_size #{inspect(invalid)}; using #{@default_max_queue_size}"
    )

    @default_max_queue_size
  end

  @impl true
  def handle_cast(message, state) when is_tuple(message) do
    Logger.debug(
      "[DNSTap.Producer] Received message: #{inspect(elem(message, 0))}, current demand: #{state.demand}, queue size: #{state.queue_len}"
    )

    if state.queue_len >= state.max_queue_size do
      # High-water mark reached: drop this message rather than grow the queue
      # (and OOM) while the downstream writer is unable to keep up. `queue_len`
      # is tracked in the state so this hot-path check is O(1) (`:queue.len/1`
      # is O(n)).
      {:noreply, [], count_drop(state)}
    else
      queue = :queue.in(message, state.queue)
      dispatch_events(queue, state.queue_len + 1, state.demand, [], state)
    end
  end

  @impl true
  def handle_demand(incoming_demand, state) do
    # Cap total demand at max_demand to prevent unbounded accumulation
    new_demand = min(state.demand + incoming_demand, state.max_demand)

    Logger.debug(
      "[DNSTap.Producer] Demand received: #{incoming_demand}, new total demand: #{new_demand}, queue size: #{state.queue_len}"
    )

    dispatch_events(state.queue, state.queue_len, new_demand, [], state)
  end

  ## Private Functions

  # Dispatch queued events based on available demand, preserving the rest of the
  # producer state. `queue_len` is threaded (and decremented per dispatched
  # event) so it stays exact without an O(n) `:queue.len/1` scan.
  @spec dispatch_events(:queue.queue(), non_neg_integer(), non_neg_integer(), [message()], t()) ::
          {:noreply, [message()], t()}
  defp dispatch_events(queue, queue_len, demand, events, state) do
    case {demand, :queue.out(queue)} do
      # No demand left - stop dispatching
      {0, _} ->
        {:noreply, Enum.reverse(events), %{state | queue: queue, queue_len: queue_len, demand: 0}}

      # Queue empty - accumulate demand
      {demand, {:empty, queue}} ->
        {:noreply, Enum.reverse(events), %{state | queue: queue, queue_len: 0, demand: demand}}

      # Dispatch one event and continue
      {demand, {{:value, event}, queue}} ->
        dispatch_events(queue, queue_len - 1, demand - 1, [event | events], state)
    end
  end

  # Count a dropped message, logging at a throttled rate to avoid amplifying a
  # flood into a log storm.
  @spec count_drop(t()) :: t()
  defp count_drop(state) do
    dropped = state.dropped + 1

    if rem(dropped, @drop_log_interval) == 0 do
      Logger.warning(
        "[DNSTap.Producer] queue full (max_queue_size=#{state.max_queue_size}); dropped #{dropped} messages so far"
      )
    end

    %{state | dropped: dropped}
  end
end
