defmodule ElixirDnstap do
  @moduledoc """
  Public API for ElixirDnstap library.

  This module provides functions to log DNS queries and responses
  using the DNSTap protocol. Messages are sent to a GenStage Producer
  for downstream processing.

  ## Usage

      # Log a client query
      ElixirDnstap.log_client_query(
        packet,
        client_addr,
        client_port,
        server_addr,
        server_port,
        :udp
      )

      # Log a client response
      ElixirDnstap.log_client_response(
        query_packet: query_packet,
        response_packet: response_packet,
        client_addr: client_addr,
        client_port: client_port,
        server_addr: server_addr,
        server_port: server_port,
        socket_protocol: :udp,
        query_time_sec: query_time_sec,
        query_time_nsec: query_time_nsec
      )
  """

  alias ElixirDnstap.{Encoder, Producer}

  @doc """
  Log a client query (CLIENT_QUERY message type).

  ## Parameters

  - `packet` - Raw DNS query packet (binary)
  - `client_addr` - Client IP address (tuple)
  - `client_port` - Client port number (integer)
  - `server_addr` - Server IP address (tuple)
  - `server_port` - Server port number (integer)
  - `socket_protocol` - Socket protocol (`:udp` or `:tcp`)

  ## Returns

  - `:ok` if the message was successfully queued
  - `{:error, :producer_not_available}` if the Producer is not running

  ## Examples

      iex> ElixirDnstap.log_client_query(
      ...>   <<1, 2, 3, 4>>,
      ...>   {192, 168, 1, 100},
      ...>   54321,
      ...>   {127, 0, 0, 1},
      ...>   5353,
      ...>   :udp
      ...> )
      :ok
  """
  @spec log_client_query(
          packet :: binary(),
          client_addr :: :inet.ip_address(),
          client_port :: non_neg_integer(),
          server_addr :: :inet.ip_address(),
          server_port :: non_neg_integer(),
          socket_protocol :: :udp | :tcp
        ) :: :ok | {:error, :producer_not_available}
  def log_client_query(
        packet,
        client_addr,
        client_port,
        server_addr,
        server_port,
        socket_protocol
      ) do
    # Encode the client query message
    message =
      Encoder.encode_client_query(
        packet,
        client_addr,
        client_port,
        server_addr,
        server_port,
        socket_protocol
      )

    # Send to Producer
    send_to_producer(message)
  end

  @doc """
  Log a client response (CLIENT_RESPONSE message type).

  ## Parameters

  Accepts a keyword list with the following keys:
  - `:query_packet` - Original DNS query packet (binary)
  - `:response_packet` - DNS response packet (binary)
  - `:client_addr` - Client IP address (tuple)
  - `:client_port` - Client port number (integer)
  - `:server_addr` - Server IP address (tuple)
  - `:server_port` - Server port number (integer)
  - `:socket_protocol` - Socket protocol (`:udp` or `:tcp`)
  - `:query_time_sec` - Query timestamp seconds
  - `:query_time_nsec` - Query timestamp nanoseconds

  ## Returns

  - `:ok` if the message was successfully queued
  - `{:error, :producer_not_available}` if the Producer is not running

  ## Examples

      iex> ElixirDnstap.log_client_response(
      ...>   query_packet: <<1, 2, 3, 4>>,
      ...>   response_packet: <<1, 2, 3, 4, 5, 6>>,
      ...>   client_addr: {192, 168, 1, 100},
      ...>   client_port: 54321,
      ...>   server_addr: {127, 0, 0, 1},
      ...>   server_port: 5353,
      ...>   socket_protocol: :udp,
      ...>   query_time_sec: 1234567890,
      ...>   query_time_nsec: 123456789
      ...> )
      :ok
  """
  @spec log_client_response(opts :: keyword()) ::
          :ok | {:error, :producer_not_available}
  def log_client_response(opts) when is_list(opts) do
    # Encode the client response message
    message = Encoder.encode_client_response(opts)

    # Send to Producer
    send_to_producer(message)
  end

  # Private helper to send message to Producer
  defp send_to_producer(message) do
    # Check if Producer is available
    case Process.whereis(Producer) do
      nil ->
        {:error, :producer_not_available}

      pid when is_pid(pid) ->
        GenStage.cast(Producer, {:notify, message})
        :ok
    end
  end
end
