defmodule SymphonyElixir.Config do
  @moduledoc """
  Runtime configuration loaded from `WORKFLOW.md`.
  """

  alias SymphonyElixir.{Config.Schema, PathSafety, Tracker}
  alias SymphonyElixir.{Workflow, WorkflowStore}

  @default_prompt_template """
  You are working on an issue from the configured tracker.

  Identifier: {{ issue.identifier }}
  Title: {{ issue.title }}

  Body:
  {% if issue.description %}
  {{ issue.description }}
  {% else %}
  No description provided.
  {% endif %}
  """

  @type codex_runtime_settings :: %{
          approval_policy: String.t() | map(),
          thread_sandbox: String.t(),
          turn_sandbox_policy: map()
        }

  @spec settings() :: {:ok, Schema.t()} | {:error, term()}
  def settings do
    WorkflowStore.settings()
  end

  @spec settings!() :: Schema.t()
  def settings! do
    case settings() do
      {:ok, settings} ->
        settings

      {:error, reason} ->
        raise ArgumentError, message: format_config_error(reason)
    end
  end

  @spec max_concurrent_agents_for_state(term()) :: pos_integer()
  def max_concurrent_agents_for_state(state_name) when is_binary(state_name) do
    config = settings!()

    Map.get(
      config.agent.max_concurrent_agents_by_state,
      Schema.normalize_issue_state(state_name),
      config.agent.max_concurrent_agents
    )
  end

  def max_concurrent_agents_for_state(_state_name), do: settings!().agent.max_concurrent_agents

  @spec codex_turn_sandbox_policy(Path.t() | nil) :: map()
  def codex_turn_sandbox_policy(workspace \\ nil) do
    case Schema.resolve_runtime_turn_sandbox_policy(settings!(), workspace) do
      {:ok, policy} ->
        policy

      {:error, reason} ->
        raise ArgumentError, message: "Invalid codex turn sandbox policy: #{inspect(reason)}"
    end
  end

  @spec workflow_prompt() :: String.t()
  def workflow_prompt do
    case Workflow.current() do
      {:ok, %{prompt_template: prompt}} ->
        if String.trim(prompt) == "", do: @default_prompt_template, else: prompt

      _ ->
        @default_prompt_template
    end
  end

  @spec server_port() :: non_neg_integer() | nil
  def server_port do
    case Application.get_env(:symphony_elixir, :server_port_override) do
      port when is_integer(port) and port >= 0 -> port
      _ -> settings!().server.port
    end
  end

  @doc false
  @spec local_workspace_root() :: Path.t()
  def local_workspace_root do
    workflow_dir = Workflow.workflow_file_path() |> Path.expand() |> Path.dirname()
    Path.expand(settings!().workspace.root, workflow_dir)
  end

  @spec validate!() :: :ok | {:error, term()}
  def validate! do
    WorkflowStore.force_reload()
  end

  @spec codex_runtime_settings(Path.t() | nil, keyword()) ::
          {:ok, codex_runtime_settings()} | {:error, term()}
  def codex_runtime_settings(workspace \\ nil, opts \\ []) do
    with {:ok, settings} <- settings() do
      with {:ok, turn_sandbox_policy} <-
             Schema.resolve_runtime_turn_sandbox_policy(settings, workspace, opts) do
        {:ok,
         %{
           approval_policy: settings.codex.approval_policy,
           thread_sandbox: settings.codex.thread_sandbox,
           turn_sandbox_policy: turn_sandbox_policy
         }}
      end
    end
  end

  @doc false
  @spec validate_settings(Schema.t()) :: :ok | {:error, term()}
  def validate_settings(settings) do
    with :ok <- validate_tracker(settings) do
      validate_review(settings)
    end
  end

  defp validate_tracker(settings) do
    if is_nil(settings.tracker.kind), do: {:error, :missing_tracker_kind}, else: Tracker.validate_config(settings.tracker)
  end

  defp validate_review(%{review: %{enabled: false}}), do: :ok

  defp validate_review(settings) do
    review = settings.review

    cond do
      settings.tracker.kind != "linear" ->
        {:error, :review_requires_linear_tracker}

      settings.worker.ssh_hosts != [] ->
        {:error, :review_does_not_support_remote_workers}

      settings.codex.thread_sandbox != "workspace-write" or not bounded_turn_policy?(settings.codex.turn_sandbox_policy) ->
        {:error, :review_requires_workspace_write_sandbox}

      true ->
        validate_review_paths(review, settings)
    end
  end

  defp bounded_turn_policy?(nil), do: true

  defp bounded_turn_policy?(%{"type" => "workspaceWrite"} = policy) do
    roots = Map.get(policy, "writableRoots", [])
    is_list(roots) and Enum.all?(roots, &(is_binary(&1) and Path.type(&1) == :absolute))
  end

  defp bounded_turn_policy?(_policy), do: false

  defp validate_review_paths(review, settings) do
    with :ok <- validate_review_executable(review.executable, settings) do
      validate_review_state_root(review.state_root, settings)
    end
  end

  defp validate_review_executable(path, settings) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, mode: mode}} ->
        cond do
          Bitwise.band(mode, 0o111) == 0 -> {:error, {:review_executable_not_executable, path}}
          writable_path_overlap?(path, settings) -> {:error, {:review_executable_worker_writable, path}}
          true -> :ok
        end

      _ ->
        {:error, {:invalid_review_executable, path}}
    end
  end

  defp validate_review_state_root(path, settings) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :directory, mode: mode}} ->
        cond do
          Bitwise.band(mode, 0o077) != 0 -> {:error, {:review_state_root_not_private, path}}
          writable_path_overlap?(path, settings) -> {:error, {:review_state_root_worker_writable, path}}
          true -> :ok
        end

      _ ->
        {:error, {:invalid_review_state_root, path}}
    end
  end

  defp writable_path_overlap?(state_root, settings) do
    extra_roots =
      (settings.codex.turn_sandbox_policy || %{})
      |> get_in(["writableRoots"])
      |> List.wrap()

    workflow_dir = Workflow.workflow_file_path() |> Path.expand() |> Path.dirname()
    workspace_root = Path.expand(settings.workspace.root, workflow_dir)
    roots = [workspace_root, System.tmp_dir!(), "/tmp"] ++ extra_roots

    canonical_state = canonical_path(state_root)

    Enum.any?(roots, fn root ->
      canonical_root = canonical_path(root)

      pairs = for writable <- [Path.expand(root), canonical_root], trusted <- [Path.expand(state_root), canonical_state], do: {writable, trusted}
      Enum.any?(pairs, fn {writable, trusted} -> path_contains?(writable, trusted) or path_contains?(trusted, writable) end)
    end)
  end

  defp canonical_path(path) when is_binary(path) do
    # stat detects symlink cycles before the segment resolver follows them.
    case File.stat(path) do
      {:error, :eloop} ->
        "/"

      _ ->
        case PathSafety.canonicalize(Path.expand(path)) do
          {:ok, canonical} -> canonical
          _ -> "/"
        end
    end
  end

  defp path_contains?("/", _child), do: true
  defp path_contains?(parent, child), do: child == parent or String.starts_with?(child, parent <> "/")

  defp format_config_error(reason) do
    case reason do
      {:invalid_workflow_config, message} ->
        "Invalid WORKFLOW.md config: #{message}"

      {:missing_workflow_file, path, raw_reason} ->
        "Missing WORKFLOW.md at #{path}: #{inspect(raw_reason)}"

      {:workflow_parse_error, raw_reason} ->
        "Failed to parse WORKFLOW.md: #{inspect(raw_reason)}"

      :workflow_front_matter_not_a_map ->
        "Failed to parse WORKFLOW.md: workflow front matter must decode to a map"

      other ->
        "Invalid WORKFLOW.md config: #{inspect(other)}"
    end
  end
end
