defmodule Dobby.HomeConfig.WriterTest do
  @moduledoc """
  The single writer (TK-018 layer B).

  Against the real house, because applying a house *is* restarting the house
  and there is no way to test that against a pretend one. The rig's own manifest
  is the starting point every scenario already trusts; what changes here is that
  the change arrives through a file somebody could have edited by hand.

  The houses written here are bound to `Dobby.HomeAssistant.Fake` at the one
  honest boundary. A YAML house always names the real client — that is the
  point of it — so the binding is swapped in the loaded struct rather than in
  the file, and the file that lands on disk is the shareable one either way.
  """

  use Dobby.RigCase

  @moduletag :capture_log

  alias Dobby.ConfigEvents
  alias Dobby.HomeConfig
  alias Dobby.HomeConfig.Applied
  alias Dobby.HomeConfig.Writer

  @house """
  house:
    id: rig
    name: Rig Home
    timezone: America/New_York
    home_assistant:
      url: http://fake.invalid:8123
    devices:
      - id: thermostat:main
        type: thermostat
        name: main thermostat
        aliases: [downstairs thermostat]
        bindings:
          climate: climate.main_floor
        settings:
          min_temperature_f: 60
          max_temperature_f: 76
  """

  setup do
    path =
      Path.join(System.tmp_dir!(), "writer-#{System.unique_integer([:positive])}.yaml")

    File.write!(path, @house)
    on_exit(fn -> File.rm(path) end)

    writer =
      start_supervised!(
        {Writer, config: on_the_fake(HomeConfig.load!(path)), name: :"writer_#{unique()}"}
      )

    ConfigEvents.subscribe()

    %{path: path, writer: writer}
  end

  defp unique, do: System.unique_integer([:positive])

  # The rig speaks to the fake, and a YAML house never says so — that is the
  # point of it. So the binding is swapped in the struct before the writer is
  # handed it, and since `to_yaml/1` emits only the url and the token, the file
  # that lands on disk is the shareable one either way.
  defp on_the_fake(%HomeConfig{house: house} = config) do
    home_assistant =
      house
      |> Keyword.fetch!(:home_assistant)
      |> Keyword.put(:client, Dobby.HomeAssistant.Fake)

    %{config | house: Keyword.put(house, :home_assistant, home_assistant)}
  end

  defp current(writer), do: Writer.current(writer)

  defp with_devices(config, devices) do
    %{config | house: Keyword.put(config.house, :devices, devices)}
  end

  defp with_system(config, changes) do
    %{config | system: struct!(config.system, changes)}
  end

  defp thermostat(id, name, entity) do
    %{
      id: id,
      name: name,
      aliases: [],
      agent_module: Dobby.DeviceAgents.Thermostat,
      bindings: %{climate: entity},
      settings: %{}
    }
  end

  describe "writing the file" do
    test "the file it writes is the file it reads back", %{path: path, writer: writer} do
      config = current(writer)

      assert {:ok, _applied} =
               Writer.save(
                 writer,
                 with_devices(config, [
                   thermostat("thermostat:attic", "attic thermostat", "climate.attic")
                 ])
               )

      assert {:ok, reread} = HomeConfig.load(path)
      assert [%{id: "thermostat:attic"}] = reread.house[:devices]
    end

    test "a written file says who wrote it and when a hand edit lands", %{
      path: path,
      writer: writer
    } do
      config = current(writer)
      assert {:ok, _applied} = Writer.save(writer, with_system(config, port: 4100))

      contents = File.read!(path)
      assert contents =~ "# This file is written by Dobby"
      assert contents =~ "restarts"
    end

    test "it leaves nothing behind beside the file", %{path: path, writer: writer} do
      config = current(writer)
      assert {:ok, _applied} = Writer.save(writer, with_system(config, port: 4100))

      siblings = Path.wildcard(Path.rootname(path) <> "*")
      assert siblings == [path]
    end

    test "a house it cannot write leaves the old one where it was", %{path: path, writer: writer} do
      config = current(writer)
      original = File.read!(path)

      unreachable = %{config | path: Path.join(path <> ".nowhere", "home.yaml")}

      assert {:error, message} = Writer.save(writer, with_system(unreachable, port: 4100))
      assert message =~ "could not write"

      assert File.read!(path) == original
      assert Writer.current(writer).system.port == nil
      assert Process.alive?(writer)
    end

    test "it will not rewrite an Elixir home" do
      writer =
        start_supervised!(
          {Writer, path: "config/homes/rig.exs", name: :writer_exs},
          id: :writer_exs
        )

      config = Writer.current(writer)

      assert {:error, message} = Writer.save(writer, config)
      assert message =~ "Dobby writes YAML"
      assert message =~ "rig.exs"
    end

    test "a house that would not boot is never the house on disk", %{path: path, writer: writer} do
      config = current(writer)
      original = File.read!(path)

      twins = [
        thermostat("thermostat:one", "the thermostat", "climate.one"),
        thermostat("thermostat:two", "the thermostat", "climate.two")
      ]

      assert {:error, message} = Writer.save(writer, with_devices(config, twins))
      assert message =~ "duplicate device names"
      assert File.read!(path) == original
    end

    test "a credential the environment cannot answer is refused, not written", %{
      path: path,
      writer: writer
    } do
      config = current(writer)
      original = File.read!(path)
      variable = "DOBBY_PROBE_#{System.unique_integer([:positive])}"

      home_assistant =
        config.house
        |> Keyword.fetch!(:home_assistant)
        |> Keyword.put(:token, "env:#{variable}")

      unresolvable = %{config | house: Keyword.put(config.house, :home_assistant, home_assistant)}

      assert {:error, message} = Writer.save(writer, unresolvable)
      assert message =~ "#{variable} is not set"
      assert File.read!(path) == original
    end
  end

  describe "applying a house" do
    test "the house Dobby is running becomes the house that was written", %{writer: writer} do
      assert Enum.map(Dobby.Home.devices(), & &1.id) == [
               "thermostat:main",
               "light:living_room",
               "vacuum:robo",
               "wifi:kitchen_tv",
               "wifi:office_printer"
             ]

      config = current(writer)

      devices = [
        thermostat("thermostat:main", "main thermostat", "climate.main_floor"),
        thermostat("thermostat:attic", "attic thermostat", "climate.attic")
      ]

      assert {:ok, applied} = Writer.save(writer, with_devices(config, devices))

      assert applied.applied == [:house]
      assert applied.on_restart == []

      assert Enum.map(Dobby.Home.devices(), & &1.id) == ["thermostat:main", "thermostat:attic"]

      # Not just the manifest: the agents for the new house are running, which
      # is the whole reason applying a house is a restart.
      assert is_pid(Dobby.Jido.whereis("thermostat:attic"))
      assert Dobby.Jido.whereis("light:living_room") == nil
    end

    test "a house that did not change is not a restart", %{writer: writer} do
      before = Dobby.Jido.whereis("thermostat:main")

      assert {:ok, applied} = Writer.save(writer, current(writer))

      assert applied.applied == []
      assert applied.on_restart == []
      assert Dobby.Jido.whereis("thermostat:main") == before
    end
  end

  describe "applying the system section" do
    test "the model alias takes effect now", %{writer: writer} do
      previous = Application.get_env(:jido_ai, :model_aliases)
      on_exit(fn -> Application.put_env(:jido_ai, :model_aliases, previous) end)

      config = current(writer)

      assert {:ok, applied} =
               Writer.save(writer, with_system(config, model: "openai:gpt-5.6-luna"))

      assert applied.applied == [:model]
      assert applied.on_restart == []
      assert Application.get_env(:jido_ai, :model_aliases) == %{capable: "openai:gpt-5.6-luna"}
    end

    test "the port and the LAN wait for a restart, and say so", %{writer: writer} do
      config = current(writer)

      assert {:ok, applied} =
               Writer.save(
                 writer,
                 with_system(config, port: 4100, lan: true, hostname: "greg.local")
               )

      assert applied.applied == []
      assert applied.on_restart == [:port, :lan, :hostname]

      # The socket is where it was: a written port is a written port.
      assert DobbyWeb.Endpoint.config(:http)[:port] == 4002
    end

    test "a model removed waits too, because the default it returns to is compiled in", %{
      writer: writer
    } do
      previous = Application.get_env(:jido_ai, :model_aliases)
      on_exit(fn -> Application.put_env(:jido_ai, :model_aliases, previous) end)

      config = current(writer)
      {:ok, _applied} = Writer.save(writer, with_system(config, model: "openai:gpt-5.6-luna"))

      assert {:ok, applied} =
               Writer.save(writer, with_system(current(writer), model: nil))

      assert applied.applied == []
      assert applied.on_restart == [:model]
    end

    test "the house and the system can change in one save", %{writer: writer} do
      previous = Application.get_env(:jido_ai, :model_aliases)
      on_exit(fn -> Application.put_env(:jido_ai, :model_aliases, previous) end)

      config = current(writer)

      changed =
        config
        |> with_devices([thermostat("thermostat:attic", "attic thermostat", "climate.attic")])
        |> with_system(model: "openai:gpt-5.6-luna", port: 4100)

      assert {:ok, applied} = Writer.save(writer, changed)

      assert applied.applied == [:house, :model]
      assert applied.on_restart == [:port]
    end
  end

  describe "announcing" do
    test "every applied change reaches dobby:config", %{writer: writer} do
      config = current(writer)

      assert {:ok, _applied} =
               Writer.save(
                 writer,
                 with_devices(config, [thermostat("thermostat:attic", "attic", "climate.attic")])
               )

      assert_receive {:applied, %Applied{} = applied}, 2_000
      assert applied.applied == [:house]
      assert [%{id: "thermostat:attic"}] = applied.config.house[:devices]
    end

    test "a change waiting for a restart is announced as one", %{writer: writer} do
      assert {:ok, _applied} = Writer.save(writer, with_system(current(writer), port: 4100))

      assert_receive {:applied, %Applied{applied: [], on_restart: [:port]}}, 2_000
    end

    test "a save that changed nothing announces nothing", %{writer: writer} do
      assert {:ok, _applied} = Writer.save(writer, current(writer))

      refute_receive {:applied, _applied}, 200
    end
  end

  describe "a house applied a moment late" do
    # Deferral exists for one caller: a change made from inside the household
    # thread (TK-018 layer E). Restarting `Dobby.Home` stops `DobbyAgent` with
    # everything else, so a confirmation that restarted the house from inside
    # its own tool call would write the file correctly and then lose the
    # sentence saying so. A browser is not inside the request it is changing; a
    # conversation is.

    test "the file and the manifest are applied, the processes are not", %{writer: writer} do
      running = Dobby.Jido.whereis("thermostat:main")

      config = current(writer)
      devices = [thermostat("thermostat:attic", "attic thermostat", "climate.attic")]

      assert {:ok, applied} =
               Writer.save(writer, with_devices(config, devices), defer_house: true)

      # Written and applied: what a caller may honestly call done.
      assert applied.applied == []
      assert applied.on_restart == [:house]
      assert File.read!(config.path) =~ "thermostat:attic"

      manifest = Application.get_env(:dobby, Dobby.Home)
      assert manifest |> Keyword.fetch!(:devices) |> Enum.map(& &1.id) == ["thermostat:attic"]

      # Not yet applied: the agents, which is the half that would have killed
      # the request that asked for this.
      assert Dobby.Jido.whereis("thermostat:main") == running
      assert Dobby.Jido.whereis("thermostat:attic") == nil
    end

    test "catching up restarts the house and announces it", %{writer: writer} do
      config = current(writer)
      devices = [thermostat("thermostat:attic", "attic thermostat", "climate.attic")]

      assert {:ok, _deferred} =
               Writer.save(writer, with_devices(config, devices), defer_house: true)

      assert {:ok, applied} = Writer.catch_up(writer)
      assert applied.applied == [:house]

      assert Enum.map(Dobby.Home.devices(), & &1.id) == ["thermostat:attic"]
      assert is_pid(Dobby.Jido.whereis("thermostat:attic"))

      assert_receive {:applied, %Applied{applied: [:house]}}, 2_000
    end

    test "catching up twice is idle the second time", %{writer: writer} do
      devices = [thermostat("thermostat:attic", "attic thermostat", "climate.attic")]

      assert {:ok, _deferred} =
               Writer.save(writer, with_devices(current(writer), devices), defer_house: true)

      assert {:ok, _applied} = Writer.catch_up(writer)
      assert Writer.catch_up(writer) == :idle
    end

    test "a writer with nothing waiting is idle, which is every turn but one", %{writer: writer} do
      assert Writer.catch_up(writer) == :idle
    end
  end

  describe "the rule about which houses are writable" do
    test "it is a pure question, answerable without writing anything", %{writer: writer} do
      # Two callers have to ask it — a surface deciding whether to offer an edit
      # at all, and this process before it touches the file — and two copies
      # would eventually be two rules.
      assert Writer.writable(current(writer)) == :ok

      exs = %HomeConfig{path: "config/homes/rig.exs", format: :exs, house: []}

      assert {:error, reason} = Writer.writable(exs)
      assert reason =~ "Dobby writes YAML"
      assert reason =~ "migrate the house to a .yaml file first"
    end

    test "a save of an Elixir house refuses with that same sentence", %{writer: writer} do
      exs = %{current(writer) | format: :exs, path: "config/homes/rig.exs"}

      assert {:error, reason} = Writer.save(writer, exs)
      assert reason == elem(Writer.writable(exs), 1)
    end
  end
end
