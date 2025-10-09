defmodule ElixirDnstap.BufferStageTest do
  use ExUnit.Case, async: true

  alias ElixirDnstap.BufferStage

  @test_query_params %{
    packet: <<1, 2, 3, 4>>,
    client_addr: {127, 0, 0, 1},
    client_port: 12_345,
    server_addr: {0, 0, 0, 0},
    server_port: 5353,
    socket_protocol: :udp
  }

  @test_response_params %{
    query_packet: <<1, 2, 3, 4>>,
    response_packet: <<5, 6, 7, 8>>,
    client_addr: {127, 0, 0, 1},
    client_port: 12_345,
    server_addr: {0, 0, 0, 0},
    server_port: 5353,
    socket_protocol: :udp,
    query_time_sec: 1_234_567_890,
    query_time_nsec: 123_456_789
  }

  describe "init/1" do
    test "initializes as producer_consumer" do
      assert {:producer_consumer, state, _} = BufferStage.init([])
      assert is_map(state)
    end
  end

  describe "handle_events/3 - encoding" do
    test "encodes client_query message to Protocol Buffers" do
      {:producer_consumer, state, _} = BufferStage.init([])
      events = [{:client_query, @test_query_params}]

      assert {:noreply, [encoded], ^state} =
               BufferStage.handle_events(events, self(), state)

      # Verify it's a valid Protocol Buffers message
      assert is_binary(encoded)
      assert %Dnstap.Frame{} = Dnstap.Frame.decode(encoded)
    end

    test "encodes client_response message to Protocol Buffers" do
      {:producer_consumer, state, _} = BufferStage.init([])
      events = [{:client_response, @test_response_params}]

      assert {:noreply, [encoded], ^state} =
               BufferStage.handle_events(events, self(), state)

      # Verify it's a valid Protocol Buffers message
      assert is_binary(encoded)
      frame = Dnstap.Frame.decode(encoded)
      assert %Dnstap.Frame{} = frame
      assert frame.message.type == :CLIENT_RESPONSE
    end

    test "encodes multiple events in batch" do
      {:producer_consumer, state, _} = BufferStage.init([])

      events = [
        {:client_query, @test_query_params},
        {:client_response, @test_response_params},
        {:client_query, @test_query_params}
      ]

      assert {:noreply, encoded_messages, ^state} =
               BufferStage.handle_events(events, self(), state)

      assert length(encoded_messages) == 3

      # Verify all messages are valid Protocol Buffers
      for message <- encoded_messages do
        assert is_binary(message)
        assert %Dnstap.Frame{} = Dnstap.Frame.decode(message)
      end
    end

    test "preserves message order during encoding" do
      {:producer_consumer, state, _} = BufferStage.init([])

      events = [
        {:client_query, %{@test_query_params | client_port: 1111}},
        {:client_query, %{@test_query_params | client_port: 2222}},
        {:client_query, %{@test_query_params | client_port: 3333}}
      ]

      assert {:noreply, encoded_messages, ^state} =
               BufferStage.handle_events(events, self(), state)

      # Decode and verify ports are in correct order
      ports =
        Enum.map(encoded_messages, fn message ->
          dnstap = Dnstap.Frame.decode(message)
          dnstap.message.query_port
        end)

      assert ports == [1111, 2222, 3333]
    end
  end

  describe "handle_events/3 - message validation" do
    test "client_query produces valid dnstap message structure" do
      {:producer_consumer, state, _} = BufferStage.init([])
      events = [{:client_query, @test_query_params}]

      {:noreply, [encoded], ^state} = BufferStage.handle_events(events, self(), state)
      frame = Dnstap.Frame.decode(encoded)

      assert frame.identity == "tenbin_cache"
      assert frame.version == "0.1.0"
      assert frame.type == :MESSAGE
      assert frame.message.type == :CLIENT_QUERY
      assert frame.message.socket_family == :INET
      assert frame.message.socket_protocol == :UDP
      assert frame.message.query_port == 12_345
      assert frame.message.response_port == 5353
      assert frame.message.query_message == <<1, 2, 3, 4>>
    end

    test "client_response produces valid dnstap message structure" do
      {:producer_consumer, state, _} = BufferStage.init([])
      events = [{:client_response, @test_response_params}]

      {:noreply, [encoded], ^state} = BufferStage.handle_events(events, self(), state)
      frame = Dnstap.Frame.decode(encoded)

      assert frame.identity == "tenbin_cache"
      assert frame.version == "0.1.0"
      assert frame.type == :MESSAGE
      assert frame.message.type == :CLIENT_RESPONSE
      assert frame.message.socket_family == :INET
      assert frame.message.socket_protocol == :UDP
      assert frame.message.query_port == 12_345
      assert frame.message.response_port == 5353
      assert frame.message.query_message == <<1, 2, 3, 4>>
      assert frame.message.response_message == <<5, 6, 7, 8>>
      assert frame.message.query_time_sec == 1_234_567_890
      assert frame.message.query_time_nsec == 123_456_789
    end
  end

  describe "error handling" do
    test "handles empty events list gracefully" do
      {:producer_consumer, state, _} = BufferStage.init([])

      assert {:noreply, [], ^state} = BufferStage.handle_events([], self(), state)
    end

    test "skips invalid message types" do
      {:producer_consumer, state, _} = BufferStage.init([])

      # Mix valid and invalid events
      events = [
        {:client_query, @test_query_params},
        {:invalid_type, %{}},
        {:client_response, @test_response_params}
      ]

      assert {:noreply, encoded_frames, ^state} =
               BufferStage.handle_events(events, self(), state)

      # Only valid events should be encoded
      assert length(encoded_frames) == 2
    end
  end

  describe "performance - batch processing" do
    test "handles large batch of events efficiently" do
      {:producer_consumer, state, _} = BufferStage.init([])

      # Create 100 events
      events =
        for i <- 1..100 do
          if rem(i, 2) == 0 do
            {:client_query, %{@test_query_params | client_port: 10_000 + i}}
          else
            {:client_response, %{@test_response_params | client_port: 10_000 + i}}
          end
        end

      # Measure encoding time
      {time_us, {:noreply, encoded_messages, ^state}} =
        :timer.tc(fn -> BufferStage.handle_events(events, self(), state) end)

      assert length(encoded_messages) == 100
      # Should complete in reasonable time (< 100ms for 100 events)
      assert time_us < 100_000

      # Verify all messages are valid Protocol Buffers
      for message <- encoded_messages do
        assert %Dnstap.Frame{} = Dnstap.Frame.decode(message)
      end
    end
  end
end
