defmodule ElixirDnstap.EncoderTest do
  use ExUnit.Case
  doctest ElixirDnstap.Encoder

  alias ElixirDnstap.Encoder

  describe "encode_client_query/6" do
    test "encodes CLIENT_QUERY message with IPv4 addresses" do
      packet = <<0x12, 0x34, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00>>
      client_addr = {192, 168, 1, 100}
      client_port = 54_321
      server_addr = {127, 0, 0, 1}
      server_port = 5353

      message =
        Encoder.encode_client_query(
          packet,
          client_addr,
          client_port,
          server_addr,
          server_port,
          :udp
        )

      assert is_binary(message)
      assert byte_size(message) > 0

      # Decode the message to verify structure
      decoded = Dnstap.Frame.decode(message)
      assert decoded.identity == "tenbin_cache"
      assert decoded.version == "0.1.0"
      assert decoded.type == :MESSAGE
      assert decoded.message.type == :CLIENT_QUERY
      assert decoded.message.socket_family == :INET
      assert decoded.message.socket_protocol == :UDP
      assert decoded.message.query_port == client_port
      assert decoded.message.response_port == server_port
      assert decoded.message.query_message == packet
    end

    test "encodes CLIENT_QUERY message with IPv6 addresses" do
      packet = <<0x12, 0x34, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00>>
      client_addr = {0x2001, 0x0DB8, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0001}
      client_port = 54_321
      server_addr = {0, 0, 0, 0, 0, 0, 0, 1}
      server_port = 5353

      message =
        Encoder.encode_client_query(
          packet,
          client_addr,
          client_port,
          server_addr,
          server_port,
          :udp
        )

      assert is_binary(message)

      decoded = Dnstap.Frame.decode(message)
      assert decoded.message.socket_family == :INET6
    end

    test "encodes CLIENT_QUERY message with TCP protocol" do
      packet = <<0x12, 0x34, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00>>
      client_addr = {192, 168, 1, 100}
      client_port = 54_321
      server_addr = {127, 0, 0, 1}
      server_port = 5353

      message =
        Encoder.encode_client_query(
          packet,
          client_addr,
          client_port,
          server_addr,
          server_port,
          :tcp
        )

      decoded = Dnstap.Frame.decode(message)
      assert decoded.message.socket_protocol == :TCP
    end
  end

  describe "encode_client_response/9" do
    test "encodes CLIENT_RESPONSE message with IPv4 addresses" do
      query_packet = <<0x12, 0x34, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00>>
      response_packet = <<0x12, 0x34, 0x81, 0x80, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00>>
      client_addr = {192, 168, 1, 100}
      client_port = 54_321
      server_addr = {127, 0, 0, 1}
      server_port = 5353
      query_time_sec = 1_600_000_000
      query_time_nsec = 123_456_789

      message =
        Encoder.encode_client_response(
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

      assert is_binary(message)
      assert byte_size(message) > 0

      decoded = Dnstap.Frame.decode(message)
      assert decoded.message.type == :CLIENT_RESPONSE
      assert decoded.message.query_message == query_packet
      assert decoded.message.response_message == response_packet
      assert decoded.message.query_time_sec == query_time_sec
      assert decoded.message.query_time_nsec == query_time_nsec
      assert decoded.message.response_time_sec != nil
      assert decoded.message.response_time_nsec != nil
    end

    test "encodes CLIENT_RESPONSE with both query and response packets" do
      query_packet = <<0xAB, 0xCD>>
      response_packet = <<0xEF, 0x01>>
      client_addr = {10, 0, 0, 1}
      client_port = 12_345
      server_addr = {10, 0, 0, 2}
      server_port = 53
      query_time_sec = 1_234_567_890
      query_time_nsec = 999_999_999

      message =
        Encoder.encode_client_response(
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

      decoded = Dnstap.Frame.decode(message)
      assert decoded.message.query_message == query_packet
      assert decoded.message.response_message == response_packet
    end
  end
end
