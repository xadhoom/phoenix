for pattern <- ["../../../installer/lib/phx_new/project.ex",
                "../../../installer/lib/phx_new/generator.ex",
                "../../../installer/lib/phx_new/single.ex",
                "../../../installer/lib/phx_new/ecto.ex",
                "../../../installer/lib/mix/tasks/phx.new.ex",
                "../../../installer/test/mix_helper.exs"],
    file <- Path.wildcard(Path.expand(pattern, __DIR__)),
    do: Code.require_file(file, __DIR__)

# Define a fake live reload socket.
defmodule Phoenix.LiveReloader.Socket do
  def child_spec(_) do
    Supervisor.Spec.worker(Task, [fn -> :ok end], restart: :temporary)
  end
end

# Here we test the installer is up to date.
defmodule Mix.Tasks.Phx.NewTest do
  use ExUnit.Case
  use RouterHelper

  import MixHelper
  import ExUnit.CaptureIO

  @moduletag :phx_new
  @epoch {{1970, 1, 1}, {0, 0, 0}}

  setup do
    # The shell asks to install npm and mix deps.
    # We will politely say not.
    send self(), {:mix_shell_input, :yes?, false}
    send self(), {:mix_shell_input, :yes?, false}
    :ok
  end

  test "bootstraps generated project" do
    Logger.disable(self())

    Application.put_env(:phx_blog, PhxBlogWeb.Endpoint,
      secret_key_base: String.duplicate("abcdefgh", 8),
      code_reloader: true)

    root = File.cwd!

    in_tmp "bootstrap", fn ->
      project_path = Path.join(File.cwd!(), "phx_blog")
      try do
        Mix.Tasks.Phx.New.run(["phx_blog", "--no-webpack", "--no-ecto"])

        in_project :phx_blog, project_path, fn _ ->
          Mix.Task.clear()
          Mix.Task.run "compile", ["--no-deps-check"]
          assert_received {:mix_shell, :info, ["Generated phx_blog app"]}
          refute_received {:mix_shell, :info, ["Generated phoenix app"]}
          Mix.shell.flush()

          # Adding a new template touches file (through mix)
          File.touch! "lib/phx_blog_web/views/layout_view.ex", @epoch
          File.write! "lib/phx_blog_web/templates/layout/another.html.eex", "oops"

          Mix.Task.clear()
          Mix.Task.run "compile", ["--no-deps-check"]
          assert File.stat!("lib/phx_blog_web/views/layout_view.ex").mtime > @epoch

          # Adding a new template triggers recompilation (through request)
          File.touch! "lib/phx_blog_web/views/page_view.ex", @epoch
          File.write! "lib/phx_blog_web/templates/page/another.html.eex", "oops"

          {:ok, _} = Application.ensure_all_started(:phx_blog)
          PhxBlogWeb.Endpoint.call(conn(:get, "/"), [])
          assert File.stat!("lib/phx_blog_web/views/page_view.ex").mtime > @epoch

          # Ensure /priv static files are copied
          assert File.exists?("priv/static/js/phoenix.js")

          # We can run tests too, starting the app.
          assert capture_io(fn ->
            capture_io(:user, fn ->
              Mix.Task.run("test", ["--no-start", "--no-compile"])
            end)
          end) =~ ~r"3 tests, 0 failures"

          if Version.match?(System.version(), ">= 1.6.0") do
            File.mkdir_p!("deps/phoenix")
            File.cp_r!(Path.join(root, ".formatter.exs"), "deps/phoenix/.formatter.exs")
            Mix.Task.run("format", ["--check-formatted"])
          end
        end
      after
        Code.delete_path Path.join(project_path, "_build/test/consolidated")
        Code.delete_path Path.join(project_path, "_build/test/lib/phx_blog/ebin")
      end
    end
  end

  test "assets are in sync with installer" do
    for file <- ~w(favicon.ico phoenix.js phoenix.png) do
      assert File.read!("priv/static/#{file}") ==
             File.read!("installer/templates/phx_static/#{file}")
    end
  end
end
