# ElixirDnstap

[![CI](https://github.com/smkwlab/elixir_dnstap/actions/workflows/elixir.yml/badge.svg)](https://github.com/smkwlab/elixir_dnstap/actions/workflows/elixir.yml)
[![Hex.pm](https://img.shields.io/hexpm/v/elixir_dnstap.svg)](https://hex.pm/packages/elixir_dnstap)
[![Documentation](https://img.shields.io/badge/docs-hexdocs-blue.svg)](https://hexdocs.pm/elixir_dnstap)
[![codecov](https://codecov.io/gh/smkwlab/elixir_dnstap/branch/main/graph/badge.svg)](https://codecov.io/gh/smkwlab/elixir_dnstap)

DNSTap logging library for Elixir - capture and export DNS query/response data using the DNSTap protocol and Frame Streams format.

## Quick Start

```elixir
# 1. Add the dependency in mix.exs
def deps do
  [{:elixir_dnstap, "~> 0.1.0"}]
end
```

```elixir
# 2. In config/config.exs, pick an output (minimal example: file output)
config :elixir_dnstap,
  enabled: true,
  output: [type: :file, path: "log/dnstap.fstrm"]
```

```elixir
# 3. ElixirDnstap.Application checks `enabled?` at boot and starts the
#    supervisor automatically, so the host only has to call
#    log_client_query/6 when a DNS packet arrives.
:ok =
  ElixirDnstap.log_client_query(
    query_packet,
    {192, 168, 1, 100},  # client_addr
    54_321,              # client_port
    {127, 0, 0, 1},      # server_addr
    5353,                # server_port
    :udp
  )
```

The resulting `log/dnstap.fstrm` can be read with the [`dnstap`](https://github.com/dnstap/golang-dnstap) command-line tool or [dnscollector](https://github.com/dmachard/go-dnscollector). See [Reading DNSTap Files](#reading-dnstap-files) below for details.

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

`elixir_dnstap` is itself an OTP application (`mod: {ElixirDnstap.Application, []}` in `mix.exs`). When the host application starts, `ElixirDnstap.Application.start/2` runs automatically as part of dependency resolution and starts `ElixirDnstap.Supervisor` whenever `:elixir_dnstap, :enabled` is `true`. **No supervision-tree wiring on the host side is required** — adding the dep and setting `enabled: true` is enough.

The setting is consulted in two places: `ElixirDnstap.Application.start/2` decides whether to start `ElixirDnstap.Supervisor` at all, and `ElixirDnstap.Supervisor.init/1` decides whether to bring up the GenStage pipeline. Starting `ElixirDnstap.Supervisor` manually while `enabled` is still `false` therefore produces an empty supervision tree, and subsequent `log_client_query/6` calls return `{:error, :producer_not_available}`. To enable logging at runtime, set `enabled: true` (via `Application.put_env/3` or your release config) before the supervisor starts.

### Logging DNS Messages

`log_client_query/6` takes positional arguments; `log_client_response/1` takes a keyword list that includes the original query packet plus the query timestamp captured at receive time.

```elixir
# Log a DNS client query
:ok =
  ElixirDnstap.log_client_query(
    query_packet,
    {127, 0, 0, 1},  # client_addr
    12_345,          # client_port
    {8, 8, 8, 8},    # server_addr
    53,              # server_port
    :udp             # :udp | :tcp
  )

# Log a DNS client response
:ok =
  ElixirDnstap.log_client_response(
    query_packet: query_packet,
    response_packet: response_packet,
    client_addr: {127, 0, 0, 1},
    client_port: 12_345,
    server_addr: {8, 8, 8, 8},
    server_port: 53,
    socket_protocol: :udp,
    query_time_sec: query_time_sec,
    query_time_nsec: query_time_nsec
  )
```

Both functions return `{:error, :producer_not_available}` if the supervision tree has not been started.

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
