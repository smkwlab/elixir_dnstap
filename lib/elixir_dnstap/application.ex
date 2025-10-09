defmodule ElixirDnstap.Application do
  @moduledoc """
  OTP Application module for ElixirDnstap.

  This module automatically starts the DNSTap Supervisor when DNSTap is enabled
  in the application configuration. The Supervisor manages the GenStage pipeline
  and writer processes.

  ## Configuration

  DNSTap can be enabled/disabled via application config:

      config :elixir_dnstap,
        enabled: true,
        output: [
          type: :tcp,
          host: "127.0.0.1",
          port: 6000
        ]

  When `enabled: false` or when the config is missing (defaults to false),
  no processes are started.

  ## Behavior

  - **enabled: true** - Starts `ElixirDnstap.Supervisor` which manages the
    GenStage pipeline (Producer -> BufferStage -> WriterConsumer) and the
    configured writer (File, UnixSocket, or TCP)
  - **enabled: false** - No processes are started, minimal resource usage

  This design allows the library to be included as a dependency without any
  overhead when DNSTap logging is not needed.
  """

  use Application
  require Logger

  alias ElixirDnstap.Config

  @impl true
  def start(_type, _args) do
    children =
      if Config.enabled?() do
        Logger.info("DNSTap is enabled, starting Supervisor")
        [ElixirDnstap.Supervisor]
      else
        Logger.debug("DNSTap is disabled, skipping Supervisor")
        []
      end

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: ElixirDnstap.ApplicationSupervisor]
    Supervisor.start_link(children, opts)
  end
end
