defmodule Parrot.Test.Assertions do
  @moduledoc """
  ExUnit assertion helpers for testing Parrot DSL handlers.

  These assertions provide expressive ways to verify call flow behavior:

  * `assert_played/2` - Assert that an audio file was played
  * `assert_bridged/2` - Assert that a call was bridged to a destination
  * `assert_answered/1` - Assert that the call was answered
  * `assert_rejected/2` - Assert that the call was rejected with a status code
  * `assert_hung_up/1` - Assert that the call was hung up
  * `assert_assign/3` - Assert that an assign has a specific value

  ## Usage

  Import these assertions in your test module:

      defmodule MyApp.IVRHandlerTest do
        use ExUnit.Case
        import Parrot.Test.Assertions

        test "plays welcome message" do
          call = Parrot.Test.call_fixture()
          result = MyApp.IVRHandler.handle_invite(call)

          assert_played(result, "welcome.wav")
        end
      end

  """

  import ExUnit.Assertions
  alias Parrot.Test.CallState

  @doc """
  Asserts that an audio file was played during the call.

  Accepts either an exact filename string or a regex pattern.

  ## Examples

      # Exact match
      assert_played(call, "welcome.wav")

      # Regex match
      assert_played(call, ~r/menu/)

      # Match with options
      assert_played(call, "music.wav", loop: true)

  """
  @spec assert_played(CallState.t(), String.t() | Regex.t(), keyword()) :: true
  def assert_played(call, pattern, opts \\ [])

  def assert_played(%CallState{} = call, %Regex{} = pattern, _opts) do
    actions = CallState.get_actions(call)

    played_files =
      actions
      |> Enum.filter(fn
        {:play, _} -> true
        {:play, _, _} -> true
        _ -> false
      end)
      |> Enum.map(fn
        {:play, file} -> file
        {:play, file, _} -> file
      end)

    matching = Enum.filter(played_files, &Regex.match?(pattern, &1))

    assert matching != [],
           """
           Expected a file matching #{inspect(pattern)} to be played.

           Files played: #{inspect(played_files)}
           All actions: #{inspect(actions)}
           """

    true
  end

  def assert_played(%CallState{} = call, filename, opts) when is_binary(filename) do
    actions = CallState.get_actions(call)

    expected_action =
      if opts == [] do
        {:play, filename}
      else
        {:play, filename, opts}
      end

    # Check for exact match or match without options
    found =
      Enum.any?(actions, fn
        ^expected_action -> true
        {:play, ^filename} when opts == [] -> true
        {:play, ^filename, _} when opts == [] -> true
        _ -> false
      end)

    played_files =
      actions
      |> Enum.filter(fn
        {:play, _} -> true
        {:play, _, _} -> true
        _ -> false
      end)

    assert found,
           """
           Expected file "#{filename}" to be played#{if opts != [], do: " with options #{inspect(opts)}", else: ""}.

           Files played: #{inspect(played_files)}
           All actions: #{inspect(actions)}
           """

    true
  end

  @doc """
  Asserts that the call was bridged to a specific destination.

  Accepts either an exact URI string or a regex pattern.

  ## Examples

      # Exact match
      assert_bridged(call, "sip:sales@internal")

      # Regex match
      assert_bridged(call, ~r/sales/)

      # Match with options
      assert_bridged(call, "sip:dest@example.com", timeout: 30_000)

  """
  @spec assert_bridged(CallState.t(), String.t() | Regex.t(), keyword()) :: true
  def assert_bridged(call, pattern, opts \\ [])

  def assert_bridged(%CallState{} = call, %Regex{} = pattern, _opts) do
    actions = CallState.get_actions(call)

    bridge_targets =
      actions
      |> Enum.filter(fn
        {:bridge, _} -> true
        {:bridge, _, _} -> true
        _ -> false
      end)
      |> Enum.map(fn
        {:bridge, target} -> target
        {:bridge, target, _} -> target
      end)

    matching = Enum.filter(bridge_targets, &Regex.match?(pattern, &1))

    assert matching != [],
           """
           Expected a bridge to a destination matching #{inspect(pattern)}.

           Bridge targets: #{inspect(bridge_targets)}
           All actions: #{inspect(actions)}
           """

    true
  end

  def assert_bridged(%CallState{} = call, target, opts) when is_binary(target) do
    actions = CallState.get_actions(call)

    expected_action =
      if opts == [] do
        {:bridge, target}
      else
        {:bridge, target, opts}
      end

    found =
      Enum.any?(actions, fn
        ^expected_action -> true
        {:bridge, ^target} when opts == [] -> true
        {:bridge, ^target, _} when opts == [] -> true
        _ -> false
      end)

    bridge_targets =
      actions
      |> Enum.filter(fn
        {:bridge, _} -> true
        {:bridge, _, _} -> true
        _ -> false
      end)

    assert found,
           """
           Expected bridge to "#{target}"#{if opts != [], do: " with options #{inspect(opts)}", else: ""}.

           Bridge actions: #{inspect(bridge_targets)}
           All actions: #{inspect(actions)}
           """

    true
  end

  @doc """
  Asserts that the call was answered.

  ## Examples

      assert_answered(call)

  """
  @spec assert_answered(CallState.t()) :: true
  def assert_answered(%CallState{} = call) do
    actions = CallState.get_actions(call)

    found = Enum.member?(actions, :answer)

    assert found,
           """
           Expected call to be answered.

           Actions: #{inspect(actions)}
           """

    true
  end

  @doc """
  Asserts that the call was rejected with a specific status code.

  ## Examples

      assert_rejected(call, 486)  # Busy here
      assert_rejected(call, 404)  # Not found

  """
  @spec assert_rejected(CallState.t(), integer()) :: true
  def assert_rejected(%CallState{} = call, status_code) when is_integer(status_code) do
    actions = CallState.get_actions(call)

    found = Enum.member?(actions, {:reject, status_code})

    reject_actions =
      Enum.filter(actions, fn
        {:reject, _} -> true
        _ -> false
      end)

    assert found,
           """
           Expected call to be rejected with status #{status_code}.

           Reject actions: #{inspect(reject_actions)}
           All actions: #{inspect(actions)}
           """

    true
  end

  @doc """
  Asserts that the call was hung up.

  ## Examples

      assert_hung_up(call)

  """
  @spec assert_hung_up(CallState.t()) :: true
  def assert_hung_up(%CallState{} = call) do
    actions = CallState.get_actions(call)

    found = Enum.member?(actions, :hangup)

    assert found,
           """
           Expected call to be hung up.

           Actions: #{inspect(actions)}
           """

    true
  end

  @doc """
  Asserts that an assign has a specific value.

  ## Examples

      assert_assign(call, :menu, :main)
      assert_assign(call, :retries, 0)

  """
  @spec assert_assign(CallState.t(), atom(), any()) :: true
  def assert_assign(%CallState{assigns: assigns} = _call, key, expected_value) do
    actual_value = Map.get(assigns, key)

    assert actual_value == expected_value,
           """
           Expected assigns[#{inspect(key)}] to be #{inspect(expected_value)},
           but got #{inspect(actual_value)}.

           All assigns: #{inspect(assigns)}
           """

    true
  end

  @doc """
  Asserts that DTMF collection was started.

  ## Examples

      assert_collecting_dtmf(call)
      assert_collecting_dtmf(call, max: 4, timeout: 5_000)

  """
  @spec assert_collecting_dtmf(CallState.t(), keyword()) :: true
  def assert_collecting_dtmf(%CallState{} = call, opts \\ []) do
    actions = CallState.get_actions(call)

    found =
      if opts == [] do
        Enum.any?(actions, fn
          {:collect_dtmf, _} -> true
          _ -> false
        end)
      else
        Enum.member?(actions, {:collect_dtmf, opts})
      end

    collect_actions =
      Enum.filter(actions, fn
        {:collect_dtmf, _} -> true
        _ -> false
      end)

    assert found,
           """
           Expected DTMF collection to be started#{if opts != [], do: " with options #{inspect(opts)}", else: ""}.

           Collect actions: #{inspect(collect_actions)}
           All actions: #{inspect(actions)}
           """

    true
  end

  @doc """
  Asserts that a prompt (play + collect) was started.

  ## Examples

      assert_prompted(call, "enter-pin.wav")
      assert_prompted(call, "enter-pin.wav", collect: [max: 4])

  """
  @spec assert_prompted(CallState.t(), String.t(), keyword()) :: true
  def assert_prompted(%CallState{} = call, filename, opts \\ []) do
    actions = CallState.get_actions(call)

    found =
      if opts == [] do
        Enum.any?(actions, fn
          {:prompt, ^filename, _} -> true
          _ -> false
        end)
      else
        Enum.member?(actions, {:prompt, filename, opts})
      end

    prompt_actions =
      Enum.filter(actions, fn
        {:prompt, _, _} -> true
        _ -> false
      end)

    assert found,
           """
           Expected prompt with file "#{filename}"#{if opts != [], do: " with options #{inspect(opts)}", else: ""}.

           Prompt actions: #{inspect(prompt_actions)}
           All actions: #{inspect(actions)}
           """

    true
  end

  @doc """
  Asserts that recording was started.

  ## Examples

      assert_recording(call, "recording.wav")
      assert_recording(call, "recording.wav", max_duration: 60_000)

  """
  @spec assert_recording(CallState.t(), String.t(), keyword()) :: true
  def assert_recording(%CallState{} = call, filename, opts \\ []) do
    actions = CallState.get_actions(call)

    expected =
      if opts == [] do
        {:record, filename}
      else
        {:record, filename, opts}
      end

    found =
      Enum.any?(actions, fn
        ^expected -> true
        {:record, ^filename} when opts == [] -> true
        {:record, ^filename, _} when opts == [] -> true
        _ -> false
      end)

    record_actions =
      Enum.filter(actions, fn
        {:record, _} -> true
        {:record, _, _} -> true
        _ -> false
      end)

    assert found,
           """
           Expected recording to file "#{filename}"#{if opts != [], do: " with options #{inspect(opts)}", else: ""}.

           Record actions: #{inspect(record_actions)}
           All actions: #{inspect(actions)}
           """

    true
  end
end
