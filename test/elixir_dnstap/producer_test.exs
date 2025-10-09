defmodule ElixirDnstap.ProducerTest do
  use ExUnit.Case, async: true

  alias ElixirDnstap.Producer

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
    test "initializes with empty queue and zero demand" do
      assert {:producer, state} = Producer.init([])
      assert state.queue == :queue.new()
      assert state.demand == 0
    end

    test "initializes with custom max_demand" do
      assert {:producer, state} = Producer.init(max_demand: 50)
      assert state.max_demand == 50
    end

    test "initializes with default max_demand of 100" do
      assert {:producer, state} = Producer.init([])
      assert state.max_demand == 100
    end
  end

  describe "handle_cast/2 - enqueue messages" do
    test "enqueues client_query message" do
      {:producer, initial_state} = Producer.init([])

      assert {:noreply, [], new_state} =
               Producer.handle_cast({:client_query, @test_query_params}, initial_state)

      assert :queue.len(new_state.queue) == 1
      assert new_state.demand == 0
    end

    test "enqueues client_response message" do
      {:producer, initial_state} = Producer.init([])

      assert {:noreply, [], new_state} =
               Producer.handle_cast({:client_response, @test_response_params}, initial_state)

      assert :queue.len(new_state.queue) == 1
      assert new_state.demand == 0
    end

    test "enqueues multiple messages in order" do
      {:producer, initial_state} = Producer.init([])

      {:noreply, [], state1} =
        Producer.handle_cast({:client_query, @test_query_params}, initial_state)

      {:noreply, [], state2} =
        Producer.handle_cast({:client_response, @test_response_params}, state1)

      {:noreply, [], state3} = Producer.handle_cast({:client_query, @test_query_params}, state2)

      assert :queue.len(state3.queue) == 3
    end

    test "dispatches events immediately when demand is available" do
      {:producer, initial_state} = Producer.init([])
      # Simulate demand from consumer
      state_with_demand = %{initial_state | demand: 5}

      assert {:noreply, events, new_state} =
               Producer.handle_cast({:client_query, @test_query_params}, state_with_demand)

      assert length(events) == 1
      assert [{:client_query, _}] = events
      assert new_state.demand == 4
      assert :queue.is_empty(new_state.queue)
    end

    test "queues message when demand is exhausted" do
      {:producer, initial_state} = Producer.init([])
      state_with_demand = %{initial_state | demand: 1}

      # First message consumes demand
      {:noreply, [_event1], state1} =
        Producer.handle_cast({:client_query, @test_query_params}, state_with_demand)

      # Second message should be queued (no demand left)
      {:noreply, [], state2} = Producer.handle_cast({:client_query, @test_query_params}, state1)

      assert state2.demand == 0
      assert :queue.len(state2.queue) == 1
    end
  end

  describe "handle_demand/2 - consumer demand" do
    test "increases demand when queue is empty" do
      {:producer, initial_state} = Producer.init([])

      assert {:noreply, [], new_state} = Producer.handle_demand(10, initial_state)

      assert new_state.demand == 10
      assert :queue.is_empty(new_state.queue)
    end

    test "dispatches queued messages when demand arrives" do
      {:producer, initial_state} = Producer.init([])

      # Queue 3 messages
      {:noreply, [], state1} =
        Producer.handle_cast({:client_query, @test_query_params}, initial_state)

      {:noreply, [], state2} = Producer.handle_cast({:client_query, @test_query_params}, state1)

      {:noreply, [], state3} = Producer.handle_cast({:client_query, @test_query_params}, state2)

      # Consumer requests 5 events
      assert {:noreply, events, new_state} = Producer.handle_demand(5, state3)

      # All 3 queued messages should be dispatched
      assert length(events) == 3
      assert new_state.demand == 2
      assert :queue.is_empty(new_state.queue)
    end

    test "dispatches only available messages when demand exceeds queue size" do
      {:producer, initial_state} = Producer.init([])

      # Queue 2 messages
      {:noreply, [], state1} =
        Producer.handle_cast({:client_query, @test_query_params}, initial_state)

      {:noreply, [], state2} = Producer.handle_cast({:client_query, @test_query_params}, state1)

      # Consumer requests 10 events (more than available)
      assert {:noreply, events, new_state} = Producer.handle_demand(10, state2)

      # Only 2 messages should be dispatched
      assert length(events) == 2
      assert new_state.demand == 8
      assert :queue.is_empty(new_state.queue)
    end

    test "accumulates demand from multiple requests" do
      {:producer, initial_state} = Producer.init([])

      {:noreply, [], state1} = Producer.handle_demand(5, initial_state)
      {:noreply, [], state2} = Producer.handle_demand(3, state1)

      assert state2.demand == 8
    end
  end

  describe "backpressure control" do
    test "respects max_demand limit" do
      {:producer, initial_state} = Producer.init(max_demand: 10)

      # Request more than max_demand
      {:noreply, [], state1} = Producer.handle_demand(20, initial_state)

      # Demand should be capped at max_demand
      assert state1.demand == 10
    end

    test "prevents demand overflow with max_demand" do
      {:producer, initial_state} = Producer.init(max_demand: 10)

      {:noreply, [], state1} = Producer.handle_demand(8, initial_state)
      {:noreply, [], state2} = Producer.handle_demand(5, state1)

      # Total demand (13) should be capped at max_demand (10)
      assert state2.demand == 10
    end
  end

  describe "integration - full pipeline" do
    test "handles realistic message flow with varying demand" do
      {:producer, initial_state} = Producer.init(max_demand: 5)

      # Step 1: Consumer requests 3 events (queue empty)
      {:noreply, [], state1} = Producer.handle_demand(3, initial_state)
      assert state1.demand == 3

      # Step 2: Receive 5 messages (3 dispatched, 2 queued)
      {:noreply, [_e1], state2} =
        Producer.handle_cast({:client_query, @test_query_params}, state1)

      {:noreply, [_e2], state3} =
        Producer.handle_cast({:client_query, @test_query_params}, state2)

      {:noreply, [_e3], state4} =
        Producer.handle_cast({:client_query, @test_query_params}, state3)

      {:noreply, [], state5} =
        Producer.handle_cast({:client_query, @test_query_params}, state4)

      {:noreply, [], state6} =
        Producer.handle_cast({:client_query, @test_query_params}, state5)

      assert state6.demand == 0
      assert :queue.len(state6.queue) == 2

      # Step 3: Consumer requests 1 more event
      {:noreply, [_e4], state7} = Producer.handle_demand(1, state6)
      assert state7.demand == 0
      assert :queue.len(state7.queue) == 1

      # Step 4: Consumer requests 2 events (1 from queue, 1 demand accumulated)
      {:noreply, [_e5], state8} = Producer.handle_demand(2, state7)
      assert state8.demand == 1
      assert :queue.is_empty(state8.queue)
    end
  end
end
