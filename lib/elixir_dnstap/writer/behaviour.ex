defmodule ElixirDnstap.WriterBehaviour do
  @moduledoc """
  Behaviour for DNSTap writers.

  This behaviour defines the interface for different output mechanisms
  (file, Unix socket, TCP) that write dnstap messages using the Frame Streams protocol.

  ## Callbacks

  - `init/1` - Initialize the writer with configuration
  - `write/2` - Write an encoded dnstap message (will be wrapped in Frame Streams)
  - `close/1` - Close the writer and cleanup resources

  ## Frame Streams Protocol

  All writers implementing this behaviour must support the Frame Streams protocol:

  - File writers: Uni-directional stream (START → DATA... → STOP)
  - Socket writers: Bi-directional stream (READY/ACCEPT/START → DATA... → FINISH)

  ## Example Implementation

      defmodule MyWriter do
        @behaviour ElixirDnstap.WriterBehaviour

        @impl true
        def init(config) do
          # Initialize resources
          {:ok, state}
        end

        @impl true
        def write(state, message) do
          # Write Frame Streams encoded message
          :ok
        end

        @impl true
        def close(state) do
          # Cleanup resources
          :ok
        end
      end
  """

  @typedoc """
  Writer state.

  The `state` type represents the internal state maintained by a DNSTap writer implementation.
  It typically contains resources such as file handles, socket references, configuration data,
  or any other information required to manage the writer's lifecycle.

  The structure of `state` is implementation-specific and may vary depending on the output
  mechanism (e.g., file, Unix socket, TCP).
  """
  @type state :: any()

  @type config :: map() | keyword()

  @doc """
  Start and initialize the writer.

  ## Parameters

  - `config` - Configuration map or keyword list

  ## Returns

  - `{:ok, state}` - Writer started successfully
  - `{:error, reason}` - Failed to start writer
  """
  @callback start(config()) :: {:ok, state()} | {:error, any()}

  @doc """
  Write an encoded dnstap message.

  The message will be automatically wrapped in Frame Streams data frames.

  ## Parameters

  - `state` - Writer state
  - `message` - Encoded dnstap Protocol Buffer message (binary)

  ## Returns

  - `:ok` - Write successful

  ## Exceptions

  May raise exceptions on write failures (e.g., broken pipe, disk full).
  """
  @callback write(state(), binary()) :: :ok

  @doc """
  Close the writer and cleanup resources.

  For Frame Streams protocol, this should:
  - File writers: Send STOP control frame
  - Socket writers: Send FINISH control frame

  ## Parameters

  - `state` - Writer state

  ## Returns

  - `:ok` - Close successful
  """
  @callback close(state()) :: :ok
end
