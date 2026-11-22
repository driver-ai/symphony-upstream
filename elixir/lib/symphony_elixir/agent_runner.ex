defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single tracker work item in its workspace with its selected agent harness.
  """

  require Logger
  alias SymphonyElixir.Antigravity.Runner, as: AntigravityRunner
  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.{Config, PromptBuilder, Tracker, Workspace}
  alias SymphonyElixir.Tracker.Issue

  @type worker_host :: String.t() | nil

  @doc false
  @spec continue_with_issue_for_test(Issue.t(), ([String.t()] -> term())) ::
          {:continue, Issue.t()} | {:done, Issue.t()} | {:error, term()}
  def continue_with_issue_for_test(%Issue{} = issue, issue_state_fetcher)
      when is_function(issue_state_fetcher, 1) do
    continue_with_issue?(issue, issue_state_fetcher)
  end

  @antigravity_model_labels [
    "model:gemini-4-neon",
    "model:gemini-4-argon",
    "model:gemini-4-carbon",
    "model:gemini-4-hydrogen"
  ]

  @doc false
  @spec harness_for_issue(Issue.t(), map() | nil, map()) ::
          {:ok, {:codex, nil}} | {:ok, {:antigravity, String.t()}} | {:error, term()}
  def harness_for_issue(
        %Issue{} = issue,
        antigravity_config \\ Config.settings!().antigravity,
        review_config \\ Config.settings!().review
      ) do
    labels = model_labels(issue)
    supported = Enum.filter(labels, &(&1 in @antigravity_model_labels))
    default_model = antigravity_default_model(antigravity_config)

    route_harness(labels, supported, default_model, antigravity_config, review_config)
  end

  defp model_labels(issue) do
    issue
    |> Issue.label_names()
    |> Enum.map(&(String.trim(&1) |> String.downcase()))
    |> Enum.filter(&String.starts_with?(&1, "model:"))
  end

  defp antigravity_default_model(%{default_model: model}) when is_binary(model) do
    case String.trim(model) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp antigravity_default_model(_config), do: nil

  defp route_harness(["model:codex"], _supported, _default_model, _antigravity_config, _review_config),
    do: {:ok, {:codex, nil}}

  defp route_harness(labels, supported, default_model, _antigravity_config, _review_config)
       when length(labels) > 1 and (supported != [] or not is_nil(default_model)),
       do: {:error, {:ambiguous_model_labels, labels}}

  defp route_harness(_labels, [label | _], _default_model, antigravity_config, review_config) do
    resolve_antigravity_harness(
      "runtime/" <> String.trim_leading(label, "model:"),
      label,
      antigravity_config,
      review_config
    )
  end

  defp route_harness([], [], default_model, antigravity_config, review_config)
       when is_binary(default_model) do
    resolve_antigravity_harness(default_model, default_model, antigravity_config, review_config)
  end

  defp route_harness(_labels, _supported, _default_model, _antigravity_config, _review_config),
    do: {:ok, {:codex, nil}}

  defp resolve_antigravity_harness(_model_alias, requested, nil, _review_config),
    do: {:error, {:antigravity_not_configured, requested}}

  defp resolve_antigravity_harness(
         _model_alias,
         _requested,
         %{external_sandbox_attested: false},
         %{enabled: true}
       ),
       do: {:error, :antigravity_external_sandbox_not_attested}

  defp resolve_antigravity_harness(model_alias, _requested, _antigravity_config, _review_config),
    do: {:ok, {:antigravity, model_alias}}

  @spec run(map(), pid() | nil, keyword()) :: :ok | no_return()
  def run(issue, codex_update_recipient \\ nil, opts \\ []) do
    # The orchestrator owns host retries so one worker lifetime never hops machines.
    worker_host = selected_worker_host(Keyword.get(opts, :worker_host), Config.settings!().worker.ssh_hosts)

    Logger.info("Starting agent run for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Agent run failed for #{issue_context(issue)}: #{inspect(reason)}")
        raise RuntimeError, "Agent run failed for #{issue_context(issue)}: #{inspect(reason)}"
    end
  end

  @stop_run_message :symphony_stop_run

  @doc """
  Ask a running agent task to stop gracefully. The active Codex turn is interrupted, its stream
  drains, and the run unwinds through its `after` blocks, so the Codex session is closed and the
  `after_run` hook executes, instead of the task being killed mid-turn. `Codex.AppServer` consumes
  the message while a turn streams; the runner consumes it between turns.
  """
  @spec request_stop(pid(), term()) :: :ok
  def request_stop(pid, reason) when is_pid(pid) do
    send(pid, {@stop_run_message, reason})
    :ok
  end

  defp run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
    Logger.info("Starting worker attempt for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    with {:ok, harness} <- harness_for_issue(issue),
         :ok <- validate_harness_host(harness, worker_host),
         hook_issue = hook_issue(issue, harness),
         {:ok, workspace} <- Workspace.create_for_issue(issue, worker_host) do
      send_worker_runtime_info(codex_update_recipient, issue, worker_host, workspace)

      try do
        with :ok <- Workspace.run_before_run_hook(workspace, hook_issue, worker_host) do
          run_harness_turns(harness, workspace, issue, codex_update_recipient, opts, worker_host)
        end
      after
        Workspace.run_after_run_hook(workspace, hook_issue, worker_host)
      end
    end
  end

  defp validate_harness_host({:antigravity, _model}, host) when is_binary(host),
    do: {:error, :antigravity_remote_workers_not_supported}

  defp validate_harness_host(_harness, _host), do: :ok

  defp hook_issue(issue, {:codex, nil}),
    do: issue |> Map.from_struct() |> Map.put(:symphony_harness, "codex")

  defp hook_issue(issue, {:antigravity, model}),
    do: issue |> Map.from_struct() |> Map.merge(%{symphony_harness: "antigravity", symphony_model_alias: model})

  defp codex_message_handler(recipient, issue) do
    fn message ->
      send_codex_update(recipient, issue, message)
    end
  end

  defp send_codex_update(recipient, %Issue{id: issue_id}, message)
       when is_binary(issue_id) and is_pid(recipient) do
    send(recipient, {:codex_worker_update, issue_id, message})
    :ok
  end

  defp send_codex_update(_recipient, _issue, _message), do: :ok

  defp send_worker_runtime_info(recipient, %Issue{id: issue_id}, worker_host, workspace)
       when is_binary(issue_id) and is_pid(recipient) and is_binary(workspace) do
    send(
      recipient,
      {:worker_runtime_info, issue_id,
       %{
         worker_host: worker_host,
         workspace_path: workspace
       }}
    )

    :ok
  end

  defp send_worker_runtime_info(_recipient, _issue, _worker_host, _workspace), do: :ok

  defp run_harness_turns({:codex, nil}, workspace, issue, recipient, opts, worker_host) do
    run_turns(AppServer, workspace, issue, recipient, opts, worker_host, nil)
  end

  defp run_harness_turns({:antigravity, model}, workspace, issue, recipient, opts, worker_host) do
    run_turns(AntigravityRunner, workspace, issue, recipient, opts, worker_host, model)
  end

  defp run_turns(module, workspace, issue, codex_update_recipient, opts, worker_host, model) do
    max_turns = Keyword.get(opts, :max_turns, Config.settings!().agent.max_turns)
    issue_state_fetcher = Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issues_by_ids/1)

    session_result =
      case module do
        AppServer -> module.start_session(workspace, worker_host: worker_host, issue: issue)
        AntigravityRunner -> module.start_session(workspace, issue, model, opts)
      end

    with {:ok, session} <- session_result do
      context = %{
        module: module,
        session: session,
        workspace: workspace,
        recipient: codex_update_recipient,
        opts: opts,
        fetcher: issue_state_fetcher,
        max_turns: max_turns
      }

      try do
        do_run_turns(context, issue, 1)
      after
        module.stop_session(session)
      end
    end
  end

  defp do_run_turns(context, issue, turn_number) do
    prompt = build_turn_prompt(issue, context.opts, turn_number, context.max_turns)

    with {:ok, turn_session} <-
           context.module.run_turn(
             context.session,
             prompt,
             issue,
             on_message: codex_message_handler(context.recipient, issue)
           ) do
      Logger.info("Completed agent run for #{issue_context(issue)} session_id=#{turn_session[:session_id]} workspace=#{context.workspace} turn=#{turn_number}/#{context.max_turns}")

      case stop_request(turn_session) do
        {:stop, reason} ->
          Logger.info("Stopping agent run for #{issue_context(issue)} on orchestrator request reason=#{inspect(reason)} turn=#{turn_number}/#{context.max_turns}")

          :ok

        :none ->
          continue_after_turn(context, issue, turn_number)
      end
    end
  end

  defp continue_after_turn(context, issue, turn_number) do
    case continue_with_issue?(issue, context.fetcher) do
      {:continue, refreshed_issue} when turn_number < context.max_turns ->
        Logger.info("Continuing agent run for #{issue_context(refreshed_issue)} after normal turn completion turn=#{turn_number}/#{context.max_turns}")

        do_run_turns(context, refreshed_issue, turn_number + 1)

      {:continue, refreshed_issue} ->
        Logger.info("Reached agent.max_turns for #{issue_context(refreshed_issue)} with issue still active; returning control to orchestrator")
        :ok

      {:done, _refreshed_issue} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  # A stop that arrived while the turn streamed is reported by the app server as a stopped turn; one
  # that arrives between turns is still in the mailbox.
  defp stop_request(%{stopped: reason}) when not is_nil(reason), do: {:stop, reason}

  defp stop_request(_turn_session) do
    receive do
      {@stop_run_message, reason} -> {:stop, reason}
    after
      0 -> :none
    end
  end

  defp build_turn_prompt(issue, opts, 1, _max_turns), do: PromptBuilder.build_prompt(issue, opts)

  defp build_turn_prompt(_issue, _opts, turn_number, max_turns) do
    """
    Continuation guidance:

    - The previous Codex turn completed normally, but the tracker work item is still in an active state.
    - This is continuation turn ##{turn_number} of #{max_turns} for the current agent run.
    - Resume from the current workspace and workpad state instead of restarting from scratch.
    - The original task instructions and prior turn context are already present in this thread, so do not restate them before acting.
    - Focus on the remaining ticket work and do not end the turn while the issue stays active unless you are truly blocked.
    """
  end

  defp continue_with_issue?(%Issue{id: issue_id} = issue, issue_state_fetcher) when is_binary(issue_id) do
    case issue_state_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if active_issue_state?(refreshed_issue.state) and issue_routable?(refreshed_issue) do
          {:continue, refreshed_issue}
        else
          {:done, refreshed_issue}
        end

      {:ok, []} ->
        {:done, issue}

      {:error, reason} ->
        {:error, {:issue_state_refresh_failed, reason}}
    end
  end

  defp continue_with_issue?(issue, _issue_state_fetcher), do: {:done, issue}

  defp active_issue_state?(state_name) when is_binary(state_name) do
    normalized_state = normalize_issue_state(state_name)

    Config.settings!().tracker.active_states
    |> Enum.any?(fn active_state -> normalize_issue_state(active_state) == normalized_state end)
  end

  defp active_issue_state?(_state_name), do: false

  defp issue_routable?(%Issue{} = issue) do
    Issue.routable?(issue, Config.settings!().tracker.required_labels)
  end

  defp selected_worker_host(nil, []), do: nil

  defp selected_worker_host(preferred_host, configured_hosts) when is_list(configured_hosts) do
    hosts =
      configured_hosts
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    case preferred_host do
      host when is_binary(host) and host != "" -> host
      _ when hosts == [] -> nil
      _ -> List.first(hosts)
    end
  end

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end
end
