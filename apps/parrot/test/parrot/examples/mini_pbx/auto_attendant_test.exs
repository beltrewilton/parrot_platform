defmodule Parrot.Examples.MiniPBX.AutoAttendantTest do
  @moduledoc """
  Tests for the Mini PBX Auto-Attendant IVR handler.

  Tests the IVR menu flow:
  - Welcome message
  - Menu options (1=sales, 2=support, 0=operator)
  - Timeout and retry handling
  - Bridge to departments
  """
  use ExUnit.Case, async: true

  alias Parrot.Call
  alias Parrot.Examples.MiniPBX.AutoAttendant

  describe "handle_invite/1" do
    test "answers and plays welcome message" do
      call =
        Call.new(
          from: "sip:external@example.com",
          to: "sip:100@pbx.local",
          method: "INVITE"
        )

      result = AutoAttendant.handle_invite(call)

      operations = result.__operations__
      assert Enum.any?(operations, &match?({:answer, _}, &1))
      assert Enum.any?(operations, &match?({:play, "welcome.wav", _}, &1))

      # Should set up menu state
      assert result.assigns[:menu] == :main
      assert result.assigns[:retries] == 0
    end
  end

  describe "handle_play_complete/2" do
    test "after welcome, prompts with main menu" do
      call =
        Call.new(
          from: "sip:external@example.com",
          to: "sip:100@pbx.local"
        )
        |> Call.assign(:menu, :main)
        |> Call.assign(:retries, 0)

      result = AutoAttendant.handle_play_complete("welcome.wav", call)

      result_call = case result do
        {:noreply, c} -> c
        c -> c
      end

      operations = result_call.__operations__

      # Should play menu and collect DTMF
      assert Enum.any?(operations, fn
        {:play, filename, _} -> String.contains?(filename, "menu")
        {:prompt, _, _} -> true
        _ -> false
      end)
    end

    test "after retry prompt, plays menu again" do
      call =
        Call.new(
          from: "sip:external@example.com",
          to: "sip:100@pbx.local"
        )
        |> Call.assign(:menu, :main)
        |> Call.assign(:retries, 1)

      result = AutoAttendant.handle_play_complete("sorry-try-again.wav", call)

      result_call = case result do
        {:noreply, c} -> c
        c -> c
      end

      operations = result_call.__operations__

      # Should play menu again
      assert Enum.any?(operations, fn
        {:play, filename, _} -> String.contains?(filename, "menu")
        {:prompt, _, _} -> true
        _ -> false
      end)
    end

    test "after goodbye, hangs up" do
      call =
        Call.new(
          from: "sip:external@example.com",
          to: "sip:100@pbx.local"
        )
        |> Call.assign(:menu, :main)

      result = AutoAttendant.handle_play_complete("goodbye.wav", call)

      result_call = case result do
        {:noreply, c} -> c
        c -> c
      end

      operations = result_call.__operations__
      assert Enum.any?(operations, &match?({:hangup, _}, &1))
    end
  end

  describe "handle_dtmf/2 menu options" do
    test "pressing 1 bridges to sales" do
      call =
        Call.new(
          from: "sip:external@example.com",
          to: "sip:100@pbx.local"
        )
        |> Call.assign(:menu, :main)
        |> Call.assign(:retries, 0)

      result = AutoAttendant.handle_dtmf("1", call)

      result_call = case result do
        {:noreply, c} -> c
        c -> c
      end

      operations = result_call.__operations__

      # Should bridge to sales
      {:bridge, dest, _opts} = Enum.find(operations, &match?({:bridge, _, _}, &1))
      assert String.contains?(dest, "sales")
    end

    test "pressing 2 bridges to support" do
      call =
        Call.new(
          from: "sip:external@example.com",
          to: "sip:100@pbx.local"
        )
        |> Call.assign(:menu, :main)

      result = AutoAttendant.handle_dtmf("2", call)

      result_call = case result do
        {:noreply, c} -> c
        c -> c
      end

      operations = result_call.__operations__

      {:bridge, dest, _opts} = Enum.find(operations, &match?({:bridge, _, _}, &1))
      assert String.contains?(dest, "support")
    end

    test "pressing 0 bridges to operator" do
      call =
        Call.new(
          from: "sip:external@example.com",
          to: "sip:100@pbx.local"
        )
        |> Call.assign(:menu, :main)

      result = AutoAttendant.handle_dtmf("0", call)

      result_call = case result do
        {:noreply, c} -> c
        c -> c
      end

      operations = result_call.__operations__

      {:bridge, dest, _opts} = Enum.find(operations, &match?({:bridge, _, _}, &1))
      assert String.contains?(dest, "operator")
    end

    test "invalid option plays error and reprompts" do
      call =
        Call.new(
          from: "sip:external@example.com",
          to: "sip:100@pbx.local"
        )
        |> Call.assign(:menu, :main)
        |> Call.assign(:retries, 0)

      result = AutoAttendant.handle_dtmf("5", call)

      result_call = case result do
        {:noreply, c} -> c
        c -> c
      end

      operations = result_call.__operations__

      # Should play invalid option message
      assert Enum.any?(operations, fn
        {:play, filename, _} -> String.contains?(filename, "invalid") or String.contains?(filename, "try-again")
        _ -> false
      end)
    end
  end

  describe "handle_dtmf/2 timeout handling" do
    test "first timeout retries" do
      call =
        Call.new(
          from: "sip:external@example.com",
          to: "sip:100@pbx.local"
        )
        |> Call.assign(:menu, :main)
        |> Call.assign(:retries, 0)

      result = AutoAttendant.handle_dtmf(:timeout, call)

      result_call = case result do
        {:noreply, c} -> c
        c -> c
      end

      # Should increment retries
      assert result_call.assigns[:retries] == 1

      operations = result_call.__operations__
      # Should play retry message
      assert Enum.any?(operations, fn
        {:play, filename, _} -> String.contains?(filename, "try-again") or String.contains?(filename, "sorry")
        _ -> false
      end)
    end

    test "second timeout retries" do
      call =
        Call.new(
          from: "sip:external@example.com",
          to: "sip:100@pbx.local"
        )
        |> Call.assign(:menu, :main)
        |> Call.assign(:retries, 1)

      result = AutoAttendant.handle_dtmf(:timeout, call)

      result_call = case result do
        {:noreply, c} -> c
        c -> c
      end

      assert result_call.assigns[:retries] == 2
    end

    test "third timeout says goodbye" do
      call =
        Call.new(
          from: "sip:external@example.com",
          to: "sip:100@pbx.local"
        )
        |> Call.assign(:menu, :main)
        |> Call.assign(:retries, 2)

      result = AutoAttendant.handle_dtmf(:timeout, call)

      result_call = case result do
        {:noreply, c} -> c
        c -> c
      end

      operations = result_call.__operations__

      # Should play goodbye
      assert Enum.any?(operations, fn
        {:play, filename, _} -> String.contains?(filename, "goodbye")
        _ -> false
      end)
    end
  end

  describe "handle_bridge_complete/2" do
    test "bridge failure plays error and hangs up" do
      call =
        Call.new(
          from: "sip:external@example.com",
          to: "sip:100@pbx.local"
        )
        |> Call.assign(:menu, :main)

      result = AutoAttendant.handle_bridge_complete({:failed, :unavailable}, call)

      result_call = case result do
        {:noreply, c} -> c
        c -> c
      end

      operations = result_call.__operations__

      # Should play error message and hangup
      assert Enum.any?(operations, fn
        {:play, filename, _} -> String.contains?(filename, "busy") or String.contains?(filename, "unavailable")
        _ -> false
      end)
      assert Enum.any?(operations, &match?({:hangup, _}, &1))
    end

    test "bridge answered returns noreply" do
      call =
        Call.new(
          from: "sip:external@example.com",
          to: "sip:100@pbx.local"
        )
        |> Call.assign(:menu, :main)

      result = AutoAttendant.handle_bridge_complete(:answered, call)

      assert match?({:noreply, _}, result)
    end
  end
end
