# ElixirDnstap

[![CI](https://github.com/smkwlab/elixir_dnstap/actions/workflows/elixir.yml/badge.svg)](https://github.com/smkwlab/elixir_dnstap/actions/workflows/elixir.yml)
[![Hex.pm](https://img.shields.io/hexpm/v/elixir_dnstap.svg)](https://hex.pm/packages/elixir_dnstap)
[![Documentation](https://img.shields.io/badge/docs-hexdocs-blue.svg)](https://hexdocs.pm/elixir_dnstap)
[![codecov](https://codecov.io/gh/smkwlab/elixir_dnstap/branch/main/graph/badge.svg)](https://codecov.io/gh/smkwlab/elixir_dnstap)

DNSTap logging library for Elixir - capture and export DNS query/response data using the DNSTap protocol and Frame Streams format.

## Features

- 📦 **Frame Streams Protocol** - Full implementation of uni-directional and bi-directional Frame Streams
- 🔄 **Multiple Output Types** - File, Unix socket, and TCP output support
- ⚡ **High Performance** - Built on GenStage with backpressure control
- 🔌 **Automatic Reconnection** - Exponential backoff for TCP/Unix socket connections
- 🎯 **Protocol Buffers** - Efficient DNSTap message encoding
- 📊 **Production Ready** - Comprehensive test coverage and error handling

## Installation

Add `elixir_dnstap` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:elixir_dnstap, "~> 0.1.0"}
  ]
end
```

## Configuration

Configure DNSTap output in your `config/config.exs`:

### File Output (Default)

```elixir
config :elixir_dnstap,
  enabled: true,
  output: [
    type: :file,
    path: "log/dnstap.fstrm"
  ]
```

### TCP Output

```elixir
config :elixir_dnstap,
  enabled: true,
  output: [
    type: :tcp,
    host: "127.0.0.1",
    port: 6000,
    timeout: 5000,
    bidirectional: true,
    reconnect: true,
    reconnect_interval: 1000,
    max_reconnect_interval: 60_000,
    max_reconnect_attempts: :infinity
  ]
```

### Unix Socket Output

```elixir
config :elixir_dnstap,
  enabled: true,
  output: [
    type: :unix_socket,
    path: "/tmp/dnstap.sock"
  ]
```

## Usage

### Starting the DNSTap Pipeline

Add `ElixirDnstap.Supervisor` to your application's supervision tree:

```elixir
defmodule MyApp.Application do
  use Application

  def start(_type, _args) do
    children = [
      # ... other children
      ElixirDnstap.Supervisor
    ]

    opts = [strategy: :one_for_one, name: MyApp.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
```

### Logging DNS Messages

```elixir
# Log a DNS client query
ElixirDnstap.log_client_query(
  query_packet,
  socket_family: :inet,
  socket_protocol: :udp,
  query_address: {127, 0, 0, 1},
  query_port: 12345,
  response_address: {8, 8, 8, 8},
  response_port: 53
)

# Log a DNS client response
ElixirDnstap.log_client_response(
  response_packet,
  socket_family: :inet,
  socket_protocol: :udp,
  query_address: {127, 0, 0, 1},
  query_port: 12345,
  response_address: {8, 8, 8, 8},
  response_port: 53
)
```

## Architecture

ElixirDnstap uses a GenStage pipeline for efficient message processing:

```
DNS Messages → Producer → BufferStage → WriterConsumer → Writer (File/TCP/Unix Socket)
                 ↓            ↓              ↓
            Backpressure  Encoding    Frame Streams
```

### Components

- **Producer** - Receives DNS messages and manages backpressure
- **BufferStage** - Encodes messages to Protocol Buffers and Frame Streams
- **WriterConsumer** - Consumes encoded frames and writes to output
- **Writers** - Handle specific output types (File, TCP, Unix Socket)

## Frame Streams Protocol

ElixirDnstap implements the [Frame Streams](https://fstrm.info/) protocol:

### Uni-directional Mode (File)
```
START → DATA* → STOP
```

### Bi-directional Mode (TCP/Unix Socket)
```
Receiver: READY
Sender:   ACCEPT → START → DATA* → FINISH
```

## Development

### Setup

```bash
# Get dependencies
mix deps.get

# Install lefthook git hooks
lefthook install
```

### Git Hooks (Lefthook)

This project uses [Lefthook](https://github.com/evilmartians/lefthook) for git hooks. On commit, the following checks are automatically run:

1. `mix format` - Auto-format code
2. `mix test --cover` - Run tests with coverage
3. `mix credo --strict` - Check code quality

To skip hooks temporarily:
```bash
LEFTHOOK=0 git commit -m "message"
```

### Testing and Quality

```bash
# Run tests
mix test

# Run tests with coverage
mix test --cover

# Check code quality
mix credo --strict

# Type checking
mix dialyzer

# Generate documentation
mix docs
```

## Reading DNSTap Files

Use the [`dnstap`](https://github.com/dnstap/golang-dnstap) command-line tool to read DNSTap files:

```bash
# Read Frame Streams file
dnstap -r log/dnstap.fstrm

# Listen on TCP socket
dnstap -l 127.0.0.1:6000 -w output.fstrm
```

## Performance

ElixirDnstap is designed for high-throughput DNS logging:

- Backpressure control prevents memory overflow
- Batch processing of frames
- Asynchronous I/O operations
- Automatic reconnection with exponential backoff

## License

MIT License - see [LICENSE](LICENSE) file for details.

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## Links

- [DNSTap Protocol](https://dnstap.info/)
- [Frame Streams](https://fstrm.info/)
- [Protocol Buffers](https://developers.google.com/protocol-buffers)
- [GenStage](https://hexdocs.pm/gen_stage)

## Acknowledgments

This library implements the DNSTap protocol specification and Frame Streams format for capturing DNS traffic data
