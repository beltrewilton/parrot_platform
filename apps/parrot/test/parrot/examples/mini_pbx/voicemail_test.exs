defmodule Parrot.Examples.MiniPBX.VoicemailTest do
  @moduledoc """
  Tests for the Mini PBX Voicemail system.

  Tests voicemail recording, storage, and retrieval:
  - Recording after greeting
  - Storage with metadata
  - Retrieval via *86
  - PIN verification
  """
  use ExUnit.Case, async: false

  alias Parrot.Call
  alias Parrot.Examples.MiniPBX.{Voicemail, Storage}

  # Start storage once for all tests
  setup_all do
    :mnesia.start()

    case Storage.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  setup do
    Storage.clear_all()
    :ok
  end

  describe "recording flow" do
    test "handle_play_complete with voicemail flag plays beep prompt" do
      call =
        Call.new(
          from: "sip:1002@pbx.local",
          to: "sip:1001@pbx.local"
        )
        |> Call.assign(:voicemail, true)
        |> Call.assign(:extension, "1001")
        |> Call.assign(:caller, "sip:1002@pbx.local")

      result = Voicemail.handle_play_complete("voicemail-greeting.wav", call)

      result_call = case result do
        {:noreply, c} -> c
        c -> c
      end

      # Should play the "leave message after beep" prompt
      operations = result_call.__operations__
      assert Enum.any?(operations, fn
        {:play, filename, _} -> String.contains?(filename, "leave-message") or String.contains?(filename, "beep")
        _ -> false
      end)
    end

    test "handle_play_complete for beep prompt starts recording" do
      call =
        Call.new(
          from: "sip:1002@pbx.local",
          to: "sip:1001@pbx.local"
        )
        |> Call.assign(:voicemail, true)
        |> Call.assign(:extension, "1001")
        |> Call.assign(:caller, "sip:1002@pbx.local")

      result = Voicemail.handle_play_complete("leave-message-after-beep.wav", call)

      result_call = case result do
        {:noreply, c} -> c
        c -> c
      end

      # Should start recording
      operations = result_call.__operations__
      assert Enum.any?(operations, &match?({:record, _, _}, &1))
    end

    test "handle_record_complete stores voicemail" do
      extension = "1001"
      caller = "sip:1002@pbx.local"

      call =
        Call.new(
          from: caller,
          to: "sip:#{extension}@pbx.local"
        )
        |> Call.assign(:voicemail, true)
        |> Call.assign(:extension, extension)
        |> Call.assign(:caller, caller)

      filename = "/tmp/voicemail/#{extension}/msg001.wav"
      duration = 15000

      result = Voicemail.handle_record_complete(filename, duration, call)

      result_call = case result do
        {:noreply, c} -> c
        c -> c
      end

      # Should have stored the voicemail
      {:ok, messages} = Storage.get_voicemails(extension)
      assert length(messages) == 1

      [msg] = messages
      assert msg.from == caller
      assert msg.file_path == filename

      # Should play confirmation and hangup
      operations = result_call.__operations__
      assert Enum.any?(operations, fn
        {:play, _, _} -> true
        _ -> false
      end)
      assert Enum.any?(operations, &match?({:hangup, _}, &1))
    end
  end

  describe "retrieval flow via *86" do
    test "handle_invite for *86 answers and prompts for PIN" do
      call =
        Call.new(
          from: "sip:1001@pbx.local",
          to: "sip:*86@pbx.local",
          method: "INVITE"
        )

      result = Voicemail.handle_invite(call)

      # Should answer
      operations = result.__operations__
      assert Enum.any?(operations, &match?({:answer, _}, &1))

      # Should prompt for PIN (either play or prompt operation)
      assert Enum.any?(operations, fn
        {:play, _, _} -> true
        {:prompt, _, _} -> true
        {:collect_dtmf, _} -> true
        _ -> false
      end)

      # Should store extension in assigns
      assert result.assigns[:extension] == "1001"
    end

    test "handle_dtmf with valid PIN plays messages" do
      extension = "1001"

      # Store some voicemails for testing
      :ok = Storage.store_voicemail(extension, "sip:alice@test.com", "/tmp/msg1.wav")
      :ok = Storage.store_voicemail(extension, "sip:bob@test.com", "/tmp/msg2.wav")

      call =
        Call.new(
          from: "sip:#{extension}@pbx.local",
          to: "sip:*86@pbx.local"
        )
        |> Call.assign(:extension, extension)
        |> Call.assign(:retrieval_mode, true)

      # Using default PIN (extension number)
      result = Voicemail.handle_dtmf(extension, call)

      result_call = case result do
        {:noreply, c} -> c
        c -> c
      end

      # Should set up to play messages
      assert result_call.assigns[:playing_voicemails] == true or
             Enum.any?(result_call.__operations__, fn
               {:play, _, _} -> true
               _ -> false
             end)
    end

    test "handle_dtmf with invalid PIN rejects" do
      call =
        Call.new(
          from: "sip:1001@pbx.local",
          to: "sip:*86@pbx.local"
        )
        |> Call.assign(:extension, "1001")
        |> Call.assign(:retrieval_mode, true)

      result = Voicemail.handle_dtmf("9999", call)

      result_call = case result do
        {:noreply, c} -> c
        c -> c
      end

      # Should play invalid PIN and hangup
      operations = result_call.__operations__
      assert Enum.any?(operations, fn
        {:play, filename, _} -> String.contains?(filename, "invalid")
        _ -> false
      end)
      assert Enum.any?(operations, &match?({:hangup, _}, &1))
    end
  end

  describe "voicemail greeting" do
    test "get_greeting returns default greeting for extension without custom greeting" do
      greeting = Voicemail.get_greeting("1001")
      assert is_binary(greeting)
      assert String.contains?(greeting, ".wav")
    end
  end

  describe "MWI notification" do
    test "notify_mwi returns ok for valid extension" do
      # MWI is a stub for now - just ensure it doesn't crash
      result = Voicemail.notify_mwi("1001")
      assert result == :ok
    end
  end
end
