defmodule PropCheck.Test.Cache.DSL do
  @moduledoc """
  Testing of the cache based on the EQC api and PropEr as backend.
  """

  use ExUnit.Case
  use PropCheck, default_opts: &PropCheck.TestHelpers.config/0
  use PropCheck.StateM.DSL
  import PropCheck.TestHelpers, except: [config: 0]

  alias PropCheck.Test.Cache
  # require Logger

  @cache_size 10

  property "run the sequential cache" do
    forall cmds <- commands(__MODULE__) do
      # Logger.debug "Commands to run: #{inspect cmds}"
      Cache.start_link(@cache_size)
      events = run_commands(cmds)
      Cache.stop()
      # Logger.debug "Events are: #{inspect events}"

      (events.result == :ok)
      # |> collect(length cmds)
      |> when_fail(
          IO.puts """
          History: #{inspect events.history, pretty: true}
          State: #{inspect events.state, pretty: true}
          Result: #{inspect events.result, pretty: true}
          """)
      # |> aggregate(command_names cmds)
      # |> collect(events
      #   |> history_of_states()
      #   |> Enum.map(fn model -> model.count end)
      #   |> Enum.max())
    end
  end

  @tag will_fail: true
  property "run the misconfigured sequential cache" do
    forall cmds <- commands(__MODULE__) do
      # Logger.debug "Commands to run: #{inspect cmds}"
      # Cache size is half as big expected, so we will find some cache misses,
      # where the model expects that the value is properly cached.
      Cache.start_link(div(@cache_size, 2))
      events = run_commands(cmds)
      Cache.stop()
      # Logger.debug "Events are: #{inspect events}"

      (events.result == :ok)
      # |> collect(length cmds)
      |> when_fail(
          IO.puts """
          History: #{inspect events.history, pretty: true}
          State: #{inspect events.state, pretty: true}
          Result: #{inspect events.result, pretty: true}
          """)
      # |> aggregate(command_names cmds)
      # |> collect(events
      #   |> history_of_states()
      #   |> Enum.map(fn model -> model.count end)
      #   |> Enum.max())
    end
    # |> fails
  end

  ###########################
  # Developing the model

  # the state for testing (= the model)
  defstruct [max: @cache_size, entries: [], count: 0]

  # extract the list of state from the history
  def history_of_states(events) do
    events.history
    |> Enum.map(fn {state, _call, _result} -> state end)
  end

  ###########################
  # Testing the command generators and such

  test "commands produces something" do
    cmd_gen = commands(__MODULE__)
    size = 10
    {:ok, cmds} = produce(cmd_gen, size)

    assert is_list(cmds)

    first = hd(cmds)
    assert {%__MODULE__{}, {:set, {:var, 1}, {:call, __MODULE__, _, _}}} = first
  end

  ###########################
  # Generators for keys and values

  @doc """
  Keys are chosen from a set of reusable keys and some arbitrary keys.

  The generator for keys is designed to allow some keys to be repeated
  multiple time. By using a restricted set of keys (with the `integer/1 generator)
  along with a much wider one, the generator should help exercising any
  code related to key reuse or matching, but without losing the ability
  to 'fuzz' the system.
  """
  def key, do: oneof([
    integer(1, @cache_size),
    integer()
    ])
  @doc "our values are integers"
  def val, do: integer()

  ###################
  # the initial state of our model
  def initial_state, do: %__MODULE__{}

  ##################
  # The command weight distribution
  def weight(_state), do: %{find: 1, cache: 3, flush: 1}

  ###### Command: find

  defcommand :find do
    def impl(key), do: Cache.find(key)
    def args(_state), do: [key()]
    def post(%__MODULE__{entries: l}, [key], res) do
      ret_val = case List.keyfind(l, key, 0, false) do
          false       -> res == {:error, :not_found}
          {^key, val} -> res == {:ok, val}
      end
      if not ret_val do
        # Logger.error "Postcondition failed: find(#{inspect key}) resulted in #{inspect res})"
      end
      ret_val
    end
  end

  defcommand :cache do
    # implement cache
    def impl(key, val), do: Cache.cache(key, val)
    # generator for args of cache
    def args(_state), do: [key(), val()]
    # what is the next state?
    def next(s = %__MODULE__{entries: l, count: n, max: m}, [k, v], _res) do
      case List.keyfind(l, k, 0, false) do
          # When the cache is at capacity, the first element is dropped (tl(L))
          # before adding the new one at the end
        false when n == m -> update_entries(s, tl(l) ++ [{k, v}])
          # When the cache still has free place, the entry is added at the end,
          # and the counter incremented
        false when n < m  -> update_entries(s, l ++ [{k, v}])
          # If the entry key is a duplicate, it replaces the old one without refreshing it
        {k, _}            -> update_entries(s, List.keyreplace(l, k, 0, {k, v}))
      end
    end
  end

  defcommand :flush do
    # implement flush
    def impl, do: Cache.flush()
    # next state is: cache is empty
    def next(state, _args, _res) do
      update_entries(state, [])
    end
    # pre condition: do not call flush() twice
    def pre(%__MODULE__{count: c}, _args), do: c != 0
  end

  defp update_entries(s = %__MODULE__{}, l) do
    %__MODULE__{s | entries: l, count: Enum.count(l)}
  end
end
