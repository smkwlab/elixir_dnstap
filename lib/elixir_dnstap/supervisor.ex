defmodule ElixirDnstap.Supervisor do
  @moduledoc """
  Manager for DNSTap writer processes.

  This module selects and starts the appropriate DNSTap writer based on configuration.
  It acts as a supervisor for the selected writer process.
  """

  use Supervisor
  require Logger

  alias ElixirDnstap.Config

  def start_link(_opts) do
    Supervisor.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children =
      if Config.enabled?() do
        try do
          {writer_module, writer_config} = Config.select_writer()
          Logger.info("DNSTap writer selected: #{inspect(writer_module)}")

          # Build GenStage pipeline: Producer -> BufferStage -> WriterConsumer -> Writer
          writer_children =
            case writer_module do
              ElixirDnstap.Writer.TCP ->
                Logger.info("Starting TCP writer under supervision")
                [%{id: writer_module, start: {writer_module, :start_link, [writer_config]}}]

              ElixirDnstap.Writer.File ->
                Logger.info("Starting File writer under supervision")
                [%{id: writer_module, start: {writer_module, :start_link, [writer_config]}}]

              ElixirDnstap.Writer.UnixSocket ->
                Logger.info("Starting UnixSocket writer under supervision")
                [%{id: writer_module, start: {writer_module, :start_link, [writer_config]}}]
            end

          # GenStage pipeline components
          producer = %{
            id: ElixirDnstap.Producer,
            start: {ElixirDnstap.Producer, :start_link, [[name: ElixirDnstap.Producer]]}
          }

          buffer_stage = %{
            id: ElixirDnstap.BufferStage,
            start:
              {ElixirDnstap.BufferStage, :start_link,
               [
                 [
                   name: ElixirDnstap.BufferStage,
                   subscribe_to: [ElixirDnstap.Producer]
                 ]
               ]}
          }

          writer_consumer = %{
            id: ElixirDnstap.WriterConsumer,
            start:
              {ElixirDnstap.WriterConsumer, :start_link,
               [
                 [
                   writer_module: writer_module,
                   subscribe_to: [{ElixirDnstap.BufferStage, max_demand: 50}]
                 ]
               ]}
          }

          Logger.info("Starting GenStage pipeline: Producer -> BufferStage -> WriterConsumer")
          writer_children ++ [producer, buffer_stage, writer_consumer]
        rescue
          error ->
            Logger.error("Failed to select DNSTap writer: #{inspect(error)}")
            []
        end
      else
        Logger.debug("DNSTap is disabled, skipping writer initialization")
        []
      end

    Supervisor.init(children, strategy: :one_for_one)
  end
end
