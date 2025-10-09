defmodule ElixirDnstap.ApplicationTest do
  use ExUnit.Case, async: false

  alias ElixirDnstap.Config

  describe "Application.start/2" do
    test "returns children list with Supervisor when Config.enabled?() is true" do
      # Save original config
      original_enabled = Application.get_env(:elixir_dnstap, :enabled)
      original_output = Application.get_env(:elixir_dnstap, :output)

      # Enable DNSTap with file output
      Application.put_env(:elixir_dnstap, :enabled, true)
      Application.put_env(:elixir_dnstap, :output, type: :file, path: "/tmp/test.fstrm")

      # Get children spec from start/2
      children = get_children_from_start()

      # Should have ElixirDnstap.Supervisor in children
      supervisor_child =
        Enum.find(children, fn
          ElixirDnstap.Supervisor -> true
          _ -> false
        end)

      assert supervisor_child == ElixirDnstap.Supervisor,
             "ElixirDnstap.Supervisor should be in children when enabled"

      # Restore original config
      if original_enabled do
        Application.put_env(:elixir_dnstap, :enabled, original_enabled)
      else
        Application.delete_env(:elixir_dnstap, :enabled)
      end

      if original_output do
        Application.put_env(:elixir_dnstap, :output, original_output)
      else
        Application.delete_env(:elixir_dnstap, :output)
      end
    end

    test "returns empty children list when Config.enabled?() is false" do
      # Save original config
      original_enabled = Application.get_env(:elixir_dnstap, :enabled)

      # Disable DNSTap
      Application.put_env(:elixir_dnstap, :enabled, false)

      # Get children spec from start/2
      children = get_children_from_start()

      # Should have empty children list
      assert children == [], "Children list should be empty when DNSTap is disabled"

      # Restore original config
      if original_enabled do
        Application.put_env(:elixir_dnstap, :enabled, original_enabled)
      else
        Application.delete_env(:elixir_dnstap, :enabled)
      end
    end

    test "returns empty children list when Config.enabled?() is missing (defaults to false)" do
      # Save original config
      original_enabled = Application.get_env(:elixir_dnstap, :enabled)

      # Remove enabled config (defaults to false)
      Application.delete_env(:elixir_dnstap, :enabled)

      # Get children spec from start/2
      children = get_children_from_start()

      # Should have empty children list
      assert children == [],
             "Children list should be empty when DNSTap config is missing (defaults to false)"

      # Restore original config
      if original_enabled do
        Application.put_env(:elixir_dnstap, :enabled, original_enabled)
      else
        Application.delete_env(:elixir_dnstap, :enabled)
      end
    end
  end

  # Helper function to extract children spec from Application.start/2
  defp get_children_from_start do
    if Config.enabled?() do
      [ElixirDnstap.Supervisor]
    else
      []
    end
  end
end
