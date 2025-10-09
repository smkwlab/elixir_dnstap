defmodule ElixirDnstapTest do
  use ExUnit.Case, async: false

  alias ElixirDnstap.Producer

  setup do
    # Ensure Application is started
    Application.ensure_all_started(:elixir_dnstap)

    # Wait for Producer to be ready
    Process.sleep(100)

    # Ensure Producer is registered
    unless Process.whereis(Producer) do
      {:ok, _pid} = Producer.start_link(name: Producer)
    end

    :ok
  end

  describe "log_client_query/6" do
    test "logs client query and sends to Producer" do
      packet = <<0x12, 0x34, 0x01, 0x00>>
      client_addr = {192, 168, 1, 100}
      client_port = 54_321
      server_addr = {127, 0, 0, 1}
      server_port = 5353
      socket_protocol = :udp

      # Log the query
      assert :ok =
               ElixirDnstap.log_client_query(
                 packet,
                 client_addr,
                 client_port,
                 server_addr,
                 server_port,
                 socket_protocol
               )

      # Verify message was queued in Producer
      # GenStage wraps the state, so we need to access state.state.queue
      full_state = :sys.get_state(Producer)
      producer_state = full_state.state
      assert :queue.len(producer_state.queue) >= 1

      # Get messages from queue
      messages = :queue.to_list(producer_state.queue)
      {:notify, message} = List.last(messages)

      # Verify it's a valid Protocol Buffers message
      assert is_binary(message)
      frame = Dnstap.Frame.decode(message)
      assert frame.type == :MESSAGE
      assert frame.message.type == :CLIENT_QUERY
      assert frame.message.query_message == packet
      assert frame.message.query_port == client_port
      assert frame.message.response_port == server_port
    end

    test "successfully returns ok when message is sent" do
      packet = <<0x12, 0x34, 0x01, 0x00>>
      client_addr = {192, 168, 1, 100}
      client_port = 54_321
      server_addr = {127, 0, 0, 1}
      server_port = 5353
      socket_protocol = :udp

      # Should succeed
      result =
        ElixirDnstap.log_client_query(
          packet,
          client_addr,
          client_port,
          server_addr,
          server_port,
          socket_protocol
        )

      assert :ok = result
    end
  end

  describe "log_client_response/1" do
    test "logs client response and sends to Producer" do
      query_packet = <<0x12, 0x34, 0x01, 0x00>>
      response_packet = <<0x12, 0x34, 0x81, 0x80>>
      client_addr = {192, 168, 1, 100}
      client_port = 54_321
      server_addr = {127, 0, 0, 1}
      server_port = 5353
      socket_protocol = :udp
      query_time_sec = 1_234_567_890
      query_time_nsec = 123_456_789

      # Log the response
      assert :ok =
               ElixirDnstap.log_client_response(
                 query_packet: query_packet,
                 response_packet: response_packet,
                 client_addr: client_addr,
                 client_port: client_port,
                 server_addr: server_addr,
                 server_port: server_port,
                 socket_protocol: socket_protocol,
                 query_time_sec: query_time_sec,
                 query_time_nsec: query_time_nsec
               )

      # Verify message was queued in Producer
      # GenStage wraps the state, so we need to access state.state.queue
      full_state = :sys.get_state(Producer)
      producer_state = full_state.state
      assert :queue.len(producer_state.queue) >= 1

      # Get the last message from queue
      messages = :queue.to_list(producer_state.queue)
      {:notify, message} = List.last(messages)

      # Verify it's a valid Protocol Buffers message
      assert is_binary(message)
      frame = Dnstap.Frame.decode(message)
      assert frame.type == :MESSAGE
      assert frame.message.type == :CLIENT_RESPONSE
      assert frame.message.query_message == query_packet
      assert frame.message.response_message == response_packet
      assert frame.message.query_port == client_port
      assert frame.message.response_port == server_port
      assert frame.message.query_time_sec == query_time_sec
      assert frame.message.query_time_nsec == query_time_nsec
    end

    test "successfully returns ok when message is sent" do
      # Should succeed
      result =
        ElixirDnstap.log_client_response(
          query_packet: <<0x12, 0x34, 0x01, 0x00>>,
          response_packet: <<0x12, 0x34, 0x81, 0x80>>,
          client_addr: {192, 168, 1, 100},
          client_port: 54_321,
          server_addr: {127, 0, 0, 1},
          server_port: 5353,
          socket_protocol: :udp,
          query_time_sec: 1_234_567_890,
          query_time_nsec: 123_456_789
        )

      assert :ok = result
    end
  end
end
