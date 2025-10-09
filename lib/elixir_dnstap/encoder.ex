defmodule ElixirDnstap.Encoder do
  @moduledoc """
  DNSTap message encoder for tenbin_cache.

  This module converts DNS packets and metadata into dnstap Protocol Buffer messages.
  Phase 1 implementation supports CLIENT_QUERY and CLIENT_RESPONSE message types only.

  ## Message Types

  - `CLIENT_QUERY` - DNS query received from client
  - `CLIENT_RESPONSE` - DNS response sent to client

  ## Usage

      # Encode a client query
      message = ElixirDnstap.Encoder.encode_client_query(
        packet,
        client_addr,
        client_port,
        server_addr,
        server_port,
        socket_protocol
      )

      # Encode a client response
      message = ElixirDnstap.Encoder.encode_client_response(
        query_packet,
        response_packet,
        client_addr,
        client_port,
        server_addr,
        server_port,
        socket_protocol,
        query_time_sec,
        query_time_nsec
      )
  """

  @identity "tenbin_cache"
  @version "0.1.0"
  @nanoseconds_per_second 1_000_000_000

  @doc """
  Encode a CLIENT_QUERY message.

  ## Parameters

  - `packet` - Raw DNS query packet (binary)
  - `client_addr` - Client IP address (tuple)
  - `client_port` - Client port number (integer)
  - `server_addr` - Server IP address (tuple)
  - `server_port` - Server port number (integer)
  - `socket_protocol` - Socket protocol (`:udp` or `:tcp`)

  ## Returns

  Encoded dnstap message as binary
  """
  def encode_client_query(
        packet,
        client_addr,
        client_port,
        server_addr,
        server_port,
        socket_protocol
      ) do
    {query_time_sec, query_time_nsec} = current_time()

    message = %Dnstap.Message{
      type: :CLIENT_QUERY,
      socket_family: socket_family(client_addr),
      socket_protocol: encode_socket_protocol(socket_protocol),
      query_address: encode_ip_address(client_addr),
      query_port: client_port,
      response_address: encode_ip_address(server_addr),
      response_port: server_port,
      query_time_sec: query_time_sec,
      query_time_nsec: query_time_nsec,
      query_message: packet
    }

    dnstap = %Dnstap.Frame{
      identity: @identity,
      version: @version,
      type: :MESSAGE,
      message: message
    }

    Dnstap.Frame.encode(dnstap)
  end

  @doc """
  Encode a CLIENT_RESPONSE message.

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

  Encoded dnstap message as binary
  """
  def encode_client_response(opts) when is_list(opts) do
    query_packet = Keyword.fetch!(opts, :query_packet)
    response_packet = Keyword.fetch!(opts, :response_packet)
    client_addr = Keyword.fetch!(opts, :client_addr)
    client_port = Keyword.fetch!(opts, :client_port)
    server_addr = Keyword.fetch!(opts, :server_addr)
    server_port = Keyword.fetch!(opts, :server_port)
    socket_protocol = Keyword.fetch!(opts, :socket_protocol)
    query_time_sec = Keyword.fetch!(opts, :query_time_sec)
    query_time_nsec = Keyword.fetch!(opts, :query_time_nsec)
    {response_time_sec, response_time_nsec} = current_time()

    message = %Dnstap.Message{
      type: :CLIENT_RESPONSE,
      socket_family: socket_family(client_addr),
      socket_protocol: encode_socket_protocol(socket_protocol),
      query_address: encode_ip_address(client_addr),
      query_port: client_port,
      response_address: encode_ip_address(server_addr),
      response_port: server_port,
      query_time_sec: query_time_sec,
      query_time_nsec: query_time_nsec,
      query_message: query_packet,
      response_time_sec: response_time_sec,
      response_time_nsec: response_time_nsec,
      response_message: response_packet
    }

    dnstap = %Dnstap.Frame{
      identity: @identity,
      version: @version,
      type: :MESSAGE,
      message: message
    }

    Dnstap.Frame.encode(dnstap)
  end

  # Get current time as {seconds, nanoseconds}
  defp current_time do
    now = System.os_time(:nanosecond)
    sec = div(now, @nanoseconds_per_second)
    nsec = rem(now, @nanoseconds_per_second)
    {sec, nsec}
  end

  # Determine socket family from IP address tuple
  defp socket_family({_, _, _, _}), do: :INET
  defp socket_family({_, _, _, _, _, _, _, _}), do: :INET6

  # Encode socket protocol
  defp encode_socket_protocol(:udp), do: :UDP
  defp encode_socket_protocol(:tcp), do: :TCP

  # Encode IP address tuple to binary
  defp encode_ip_address({a, b, c, d}) do
    <<a, b, c, d>>
  end

  defp encode_ip_address({a, b, c, d, e, f, g, h}) do
    <<a::16, b::16, c::16, d::16, e::16, f::16, g::16, h::16>>
  end
end
