defmodule SymphonyElixir.Codex.DynamicTool do
  @moduledoc """
  Dispatches client-side tool calls to the configured tracker adapter.
  """

  alias SymphonyElixir.Tracker

  @spec execute(String.t() | nil, term(), map(), keyword()) :: map()
  def execute(tool, arguments, binding, opts \\ []) do
    Tracker.execute_bound_agent_tool(binding, tool, arguments, opts)
  end

  @spec bind(Path.t() | nil) :: map()
  def bind(workspace \\ nil) do
    Tracker.bind_agent_tools(workspace)
  end
end
