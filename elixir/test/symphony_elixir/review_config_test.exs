defmodule SymphonyElixir.ReviewConfigTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.Codex.DynamicTool
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.ReviewRunnerFixture

  setup do
    # CI checks out outside /tmp. Local checkouts under /tmp can provide another
    # fixture parent, so these tests still exercise the real writable-root check.
    parent = System.get_env("REVIEW_TEST_TRUSTED_ROOT", File.cwd!())
    root = Path.join(parent, ".review-config-#{System.unique_integer([:positive])}")
    review = ReviewRunnerFixture.create!(root)

    {:ok, settings} =
      Schema.parse(%{
        "review" => Map.take(review, [:enabled, :executable, :state_root]),
        "tracker" => %{"kind" => "linear", "api_key" => "test-token", "project_slug" => "project"},
        "workspace" => %{"root" => review.workspace},
        "codex" => %{"thread_sandbox" => "workspace-write"}
      })

    on_exit(fn -> File.rm_rf(root) end)
    %{root: root, review: review, settings: settings}
  end

  test "review schema rejects invalid types before path validation" do
    assert {:error, _} = Schema.parse(%{review: %{enabled: "invalid"}})
    assert {:error, _} = Schema.parse(%{review: %{enabled: true, executable: 42, state_root: []}})
    {:ok, invalid_provider} = Schema.parse(%{tracker: %{kind: "linear", provider: %{api_key: "token", project_slug: 42}}})
    assert {:error, :missing_linear_project_slug} = Config.validate_settings(invalid_provider)
  end

  test "project scope type supports Ecto storage round trips and rejects invalid scalars" do
    type = Schema.StringOrList
    assert Ecto.Type.type(type) == {:array, :string}
    assert Ecto.Type.embed_as(type, :json) == :self

    for value <- ["one", ["one", "two"]] do
      assert {:ok, ^value} = Ecto.Type.cast(type, value)
      assert {:ok, ^value} = Ecto.Type.dump(type, value)
      assert {:ok, ^value} = Ecto.Type.load(type, value)
    end

    assert :error = Ecto.Type.cast(type, 42)
    assert :error = Ecto.Type.dump(type, 42)
    assert :error = Ecto.Type.load(type, 42)
  end

  test "valid installed configuration is accepted; disabled mode preserves unsupported deployments", c do
    assert :ok = Config.validate_settings(c.settings)
    disabled = %{c.settings | review: %{c.settings.review | enabled: false}, worker: %{c.settings.worker | ssh_hosts: ["remote"]}}
    assert :ok = Config.validate_settings(disabled)
    assert {:error, :review_does_not_support_remote_workers} = Config.validate_settings(%{disabled | review: c.settings.review})
    other_tracker = %{c.settings | tracker: %{c.settings.tracker | kind: "memory"}}
    assert {:error, :review_requires_linear_tracker} = Config.validate_settings(other_tracker)
  end

  test "both thread and turn sandboxes must have bounded workspace write access", c do
    settings = c.settings
    assert {:error, :review_requires_workspace_write_sandbox} = Config.validate_settings(put_in(settings.codex.thread_sandbox, "danger-full-access"))

    for policy <- [
          %{"type" => "dangerFullAccess"},
          %{"type" => "externalSandbox"},
          %{},
          %{"type" => "workspaceWrite", "writableRoots" => [nil]},
          %{"type" => "workspaceWrite", "writableRoots" => ["relative"]}
        ] do
      assert {:error, :review_requires_workspace_write_sandbox} = Config.validate_settings(put_in(settings.codex.turn_sandbox_policy, policy))
    end

    assert :ok = Config.validate_settings(put_in(settings.codex.turn_sandbox_policy, %{"type" => "workspaceWrite", "writableRoots" => [c.review.workspace]}))
  end

  test "missing, nonexecutable and nonprivate installed paths fail closed", c do
    settings = c.settings
    assert {:error, {:invalid_review_executable, _}} = Config.validate_settings(put_in(settings.review.executable, Path.join(c.root, "missing")))
    File.chmod!(c.review.executable, 0o600)
    assert {:error, {:review_executable_not_executable, _}} = Config.validate_settings(c.settings)
    File.chmod!(c.review.executable, 0o700)
    assert {:error, {:invalid_review_state_root, _}} = Config.validate_settings(put_in(settings.review.state_root, Path.join(c.root, "missing")))
    File.chmod!(c.review.state_root, 0o755)
    assert {:error, {:review_state_root_not_private, _}} = Config.validate_settings(c.settings)
  end

  test "workspace, temporary, extra-root and replaceable symlink paths cannot become authority", c do
    settings = c.settings

    for writable <- [c.review.workspace, System.tmp_dir!()] do
      path = Path.join(writable, "runner-#{System.unique_integer([:positive])}")
      File.cp!(c.review.executable, path)
      File.chmod!(path, 0o700)
      on_exit(fn -> File.rm(path) end)
      assert {:error, {:review_executable_worker_writable, _}} = Config.validate_settings(put_in(settings.review.executable, path))
    end

    policy = %{"type" => "workspaceWrite", "writableRoots" => [c.review.state_root]}
    assert {:error, {:review_state_root_worker_writable, _}} = Config.validate_settings(put_in(settings.codex.turn_sandbox_policy, policy))
    loop = Path.join(c.root, "loop")
    File.ln_s!(loop, loop)
    cyclic_policy = %{"type" => "workspaceWrite", "writableRoots" => [loop]}

    assert {:error, {:review_executable_worker_writable, _}} =
             Config.validate_settings(put_in(settings.codex.turn_sandbox_policy, cyclic_policy))

    link = Path.join(c.review.workspace, "trusted-link")
    File.ln_s!(c.review.executable, link)
    assert {:error, {:review_executable_worker_writable, _}} = Config.validate_settings(put_in(settings.review.executable, link))
    File.rm!(link)
    File.ln_s!(c.review.workspace, Path.join(c.root, "state-link"))
    File.chmod!(c.review.workspace, 0o700)
    assert {:error, {:review_state_root_worker_writable, _}} = Config.validate_settings(put_in(settings.review.state_root, Path.join(c.root, "state-link")))
  end

  test "session binding captures the nested clone and survives remote and workflow changes", c do
    repo = Path.join(c.review.workspace, "repo")
    File.mkdir_p!(repo)
    {_, 0} = System.cmd("git", ["init", "-q", repo])
    {_, 0} = System.cmd("git", ["-C", repo, "remote", "add", "origin", "git@github.com:Driver-AI/Runtime.git"])
    workflow = Workflow.workflow_file_path()
    write_workflow_file!(workflow, workspace_root: c.review.workspace)
    source = File.read!(workflow)
    enabled = "review:\n  enabled: true\n  executable: #{c.review.executable}\n  state_root: #{c.review.state_root}\n"
    File.write!(workflow, String.replace(source, "---\n", "---\n" <> enabled, global: false))
    assert :ok = WorkflowStore.force_reload()
    binding = DynamicTool.bind(c.review.workspace)
    assert binding.repository == "driver-ai/runtime"
    assert binding.review.enabled
    assert Enum.map(binding.tool_specs, & &1["name"]) == ~w(symphony_review linear_read linear_comment linear_attach_pr linear_transition)
    {_, 0} = System.cmd("git", ["-C", repo, "remote", "set-url", "origin", "https://github.com/other/repo.git"])
    write_workflow_file!(workflow, tracker_kind: "memory")
    assert DynamicTool.bind(c.review.workspace).tool_specs == []
    response = DynamicTool.execute("linear_graphql", %{"query" => "mutation { issueUpdate }"}, binding)
    refute response["success"]
    assert binding.repository == "driver-ai/runtime"
    assert binding.review.executable == c.review.executable
    {_, 0} = System.cmd("git", ["-C", repo, "remote", "set-url", "origin", "https://example.test/other/repo.git"])
    assert DynamicTool.bind(c.review.workspace).repository == nil
  end
end
