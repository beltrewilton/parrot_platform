defmodule Parrot.InviteHandlerTest do
  use ExUnit.Case, async: true

  alias Parrot.Call

  describe "behaviour definition" do
    test "defines handle_invite/1 callback" do
      callbacks = Parrot.InviteHandler.behaviour_info(:callbacks)
      assert {:handle_invite, 1} in callbacks
    end

    test "defines handle_play_complete/2 callback" do
      callbacks = Parrot.InviteHandler.behaviour_info(:callbacks)
      assert {:handle_play_complete, 2} in callbacks
    end

    test "defines handle_dtmf/2 callback" do
      callbacks = Parrot.InviteHandler.behaviour_info(:callbacks)
      assert {:handle_dtmf, 2} in callbacks
    end

    test "defines handle_prompt_complete/3 callback" do
      callbacks = Parrot.InviteHandler.behaviour_info(:callbacks)
      assert {:handle_prompt_complete, 3} in callbacks
    end

    test "defines handle_bridge_complete/2 callback" do
      callbacks = Parrot.InviteHandler.behaviour_info(:callbacks)
      assert {:handle_bridge_complete, 2} in callbacks
    end

    test "defines handle_fork_complete/2 callback" do
      callbacks = Parrot.InviteHandler.behaviour_info(:callbacks)
      assert {:handle_fork_complete, 2} in callbacks
    end

    test "defines handle_record_complete/3 callback" do
      callbacks = Parrot.InviteHandler.behaviour_info(:callbacks)
      assert {:handle_record_complete, 3} in callbacks
    end

    test "defines handle_conference_join/2 callback" do
      callbacks = Parrot.InviteHandler.behaviour_info(:callbacks)
      assert {:handle_conference_join, 2} in callbacks
    end

    test "defines handle_conference_leave/3 callback" do
      callbacks = Parrot.InviteHandler.behaviour_info(:callbacks)
      assert {:handle_conference_leave, 3} in callbacks
    end

    test "defines handle_fork_media_connected/2 callback" do
      callbacks = Parrot.InviteHandler.behaviour_info(:callbacks)
      assert {:handle_fork_media_connected, 2} in callbacks
    end

    test "defines handle_hangup/1 callback" do
      callbacks = Parrot.InviteHandler.behaviour_info(:callbacks)
      assert {:handle_hangup, 1} in callbacks
    end

    test "defines handle_fork_media_error/3 callback" do
      callbacks = Parrot.InviteHandler.behaviour_info(:callbacks)
      assert {:handle_fork_media_error, 3} in callbacks
    end

    test "defines all 21 expected callbacks" do
      callbacks = Parrot.InviteHandler.behaviour_info(:callbacks)
      assert length(callbacks) == 21
    end

    # Early Media callback (183 Session Progress)
    test "defines handle_early_media/2 callback" do
      callbacks = Parrot.InviteHandler.behaviour_info(:callbacks)
      assert {:handle_early_media, 2} in callbacks
    end

    # RFC 3311 UPDATE callbacks
    test "defines handle_update/2 callback (RFC 3311)" do
      callbacks = Parrot.InviteHandler.behaviour_info(:callbacks)
      assert {:handle_update, 2} in callbacks
    end

    test "defines handle_update_complete/2 callback (RFC 3311)" do
      callbacks = Parrot.InviteHandler.behaviour_info(:callbacks)
      assert {:handle_update_complete, 2} in callbacks
    end

    test "defines handle_update_failed/3 callback (RFC 3311)" do
      callbacks = Parrot.InviteHandler.behaviour_info(:callbacks)
      assert {:handle_update_failed, 3} in callbacks
    end

    # T038: Unit test for handle_media_started/1 callback definition
    test "defines handle_media_started/1 callback (T038, FR-010, US4)" do
      callbacks = Parrot.InviteHandler.behaviour_info(:callbacks)
      assert {:handle_media_started, 1} in callbacks
    end

    # T039: Unit test for handle_media_stopped/2 callback definition
    test "defines handle_media_stopped/2 callback (T039, FR-011, US4)" do
      callbacks = Parrot.InviteHandler.behaviour_info(:callbacks)
      assert {:handle_media_stopped, 2} in callbacks
    end

    test "defines handle_sdp_error/2 callback (T029)" do
      callbacks = Parrot.InviteHandler.behaviour_info(:callbacks)
      assert {:handle_sdp_error, 2} in callbacks
    end

    test "defines handle_tts_error/3 callback (T042, FR-017)" do
      callbacks = Parrot.InviteHandler.behaviour_info(:callbacks)
      assert {:handle_tts_error, 3} in callbacks
    end
  end

  describe "use Parrot.InviteHandler" do
    defmodule MinimalHandler do
      use Parrot.InviteHandler

      def handle_invite(invite) do
        invite
        |> answer()
        |> play("welcome.wav")
      end
    end

    test "provides default handle_play_complete/2 implementation" do
      call = Call.new()
      assert {:noreply, ^call} = MinimalHandler.handle_play_complete("file.wav", call)
    end

    test "provides default handle_dtmf/2 implementation" do
      call = Call.new()
      assert {:noreply, ^call} = MinimalHandler.handle_dtmf("1", call)
    end

    test "provides default handle_prompt_complete/3 implementation" do
      call = Call.new()
      assert {:noreply, ^call} = MinimalHandler.handle_prompt_complete("file.wav", "123", call)
    end

    test "provides default handle_bridge_complete/2 implementation" do
      call = Call.new()
      assert {:noreply, ^call} = MinimalHandler.handle_bridge_complete(:answered, call)
    end

    test "provides default handle_fork_complete/2 implementation" do
      call = Call.new()
      assert {:noreply, ^call} = MinimalHandler.handle_fork_complete(:answered, call)
    end

    test "provides default handle_record_complete/3 implementation" do
      call = Call.new()
      assert {:noreply, ^call} = MinimalHandler.handle_record_complete("file.wav", 5000, call)
    end

    test "provides default handle_conference_join/2 implementation" do
      call = Call.new()
      assert {:noreply, ^call} = MinimalHandler.handle_conference_join("room-123", call)
    end

    test "provides default handle_conference_leave/3 implementation" do
      call = Call.new()
      assert {:noreply, ^call} = MinimalHandler.handle_conference_leave("room-123", :normal, call)
    end

    test "provides default handle_fork_media_connected/2 implementation" do
      call = Call.new()

      assert {:noreply, ^call} =
               MinimalHandler.handle_fork_media_connected("fork-abc123", call)
    end

    test "provides default handle_fork_media_error/3 implementation" do
      call = Call.new()

      assert {:noreply, ^call} =
               MinimalHandler.handle_fork_media_error("fork-abc123", :connection_refused, call)
    end

    test "provides default handle_hangup/1 implementation" do
      call = Call.new()
      assert {:noreply, ^call} = MinimalHandler.handle_hangup(call)
    end

    test "provides default handle_sdp_error/2 implementation that rejects with 488 (T029, FR-012)" do
      call = Call.new()
      # Default implementation should reject with 488 Not Acceptable Here
      result = MinimalHandler.handle_sdp_error(:codec_mismatch, call)
      operations = Call.get_operations(result)
      assert [{:reject, 488}] = operations
    end

    test "provides default handle_tts_error/3 implementation that logs and returns {:noreply, call} (T042, FR-018)" do
      call = Call.new()
      # Default implementation should log warning and return {:noreply, call}
      result = MinimalHandler.handle_tts_error("Hello world", :synthesis_failed, call)
      # Should return {:noreply, call} (consistent with other callbacks)
      assert result == {:noreply, call}
    end

    # T038/T043: Unit test for default handle_media_started/1 implementation
    test "provides default handle_media_started/1 implementation (T038, T043, FR-010, US4)" do
      call = Call.new()
      # Default implementation should return {:noreply, call}
      assert {:noreply, ^call} = MinimalHandler.handle_media_started(call)
    end

    # T039/T043: Unit test for default handle_media_stopped/2 implementation
    test "provides default handle_media_stopped/2 implementation (T039, T043, FR-011, US4)" do
      call = Call.new()
      # Default implementation should return {:noreply, call}
      # Reason could be :normal, :terminated, etc.
      assert {:noreply, ^call} = MinimalHandler.handle_media_stopped(:normal, call)
    end

    test "imports Parrot.Call functions for pipeline operations" do
      invite = Call.new(from: "sip:alice@example.com", to: "sip:100@pbx.local")
      result = MinimalHandler.handle_invite(invite)

      # Verify the pipeline operations were applied
      operations = Call.get_operations(result)
      assert [{:answer, []}, {:play, "welcome.wav", []}] = operations
    end

    # Early Media callback default
    test "provides default handle_early_media/2 implementation returning {:noreply, call}" do
      call = Call.new()
      response = %{status: 183, body: "v=0\r\n"}
      assert {:noreply, ^call} = MinimalHandler.handle_early_media(response, call)
    end

    # RFC 3311 UPDATE callback defaults
    test "provides default handle_update/2 implementation returning {:noreply, call}" do
      call = Call.new()
      request = %{method: :update, body: "v=0\r\n"}
      assert {:noreply, ^call} = MinimalHandler.handle_update(request, call)
    end

    test "provides default handle_update_complete/2 implementation returning {:noreply, call}" do
      call = Call.new()
      response = %{status: 200, body: "v=0\r\n"}
      assert {:noreply, ^call} = MinimalHandler.handle_update_complete(response, call)
    end

    test "provides default handle_update_failed/3 implementation returning {:noreply, call}" do
      call = Call.new()
      response = %{status: 488, reason: "Not Acceptable Here"}
      assert {:noreply, ^call} = MinimalHandler.handle_update_failed(488, response, call)
    end
  end

  describe "overriding callbacks" do
    defmodule CustomHandler do
      use Parrot.InviteHandler

      def handle_invite(invite) do
        invite
        |> answer()
        |> assign(:menu, :main)
        |> play("welcome.wav")
      end

      def handle_dtmf("1", %{assigns: %{menu: :main}} = call) do
        call
        |> assign(:menu, :sales)
        |> play("sales-menu.wav")
      end

      def handle_dtmf("2", %{assigns: %{menu: :main}} = call) do
        call
        |> assign(:menu, :support)
        |> bridge("sip:support@internal")
      end

      def handle_dtmf(:timeout, call) do
        call |> play("goodbye.wav")
      end

      def handle_dtmf(_digit, call) do
        call |> play("invalid-option.wav")
      end

      def handle_play_complete("goodbye.wav", call) do
        call |> hangup()
      end

      def handle_play_complete(_filename, call) do
        {:noreply, call}
      end

      def handle_hangup(call) do
        # Custom cleanup logic
        {:noreply, %{call | assigns: Map.put(call.assigns, :cleaned_up, true)}}
      end
    end

    test "handle_invite returns pipeline with answer and play" do
      invite = Call.new(from: "sip:alice@example.com", to: "sip:100@pbx.local")
      result = CustomHandler.handle_invite(invite)

      assert result.assigns == %{menu: :main}
      operations = Call.get_operations(result)
      assert [{:answer, []}, {:play, "welcome.wav", []}] = operations
    end

    test "handle_dtmf pattern matches on digit and assigns" do
      call = Call.new(assigns: %{menu: :main})
      result = CustomHandler.handle_dtmf("1", call)

      assert result.assigns.menu == :sales
      operations = Call.get_operations(result)
      assert [{:play, "sales-menu.wav", []}] = operations
    end

    test "handle_dtmf routes to sales menu on digit 1" do
      call = Call.new(assigns: %{menu: :main})
      result = CustomHandler.handle_dtmf("1", call)

      assert result.assigns.menu == :sales
    end

    test "handle_dtmf routes to support on digit 2" do
      call = Call.new(assigns: %{menu: :main})
      result = CustomHandler.handle_dtmf("2", call)

      assert result.assigns.menu == :support
      operations = Call.get_operations(result)
      assert [{:bridge, "sip:support@internal", []}] = operations
    end

    test "handle_dtmf handles timeout" do
      call = Call.new(assigns: %{menu: :main})
      result = CustomHandler.handle_dtmf(:timeout, call)

      operations = Call.get_operations(result)
      assert [{:play, "goodbye.wav", []}] = operations
    end

    test "handle_dtmf handles invalid digits with fallback" do
      call = Call.new(assigns: %{menu: :main})
      result = CustomHandler.handle_dtmf("9", call)

      operations = Call.get_operations(result)
      assert [{:play, "invalid-option.wav", []}] = operations
    end

    test "handle_play_complete can trigger hangup" do
      call = Call.new()
      result = CustomHandler.handle_play_complete("goodbye.wav", call)

      operations = Call.get_operations(result)
      assert [{:hangup, []}] = operations
    end

    test "handle_play_complete with other files returns noreply" do
      call = Call.new()
      assert {:noreply, ^call} = CustomHandler.handle_play_complete("welcome.wav", call)
    end

    test "handle_hangup can perform custom cleanup" do
      call = Call.new(assigns: %{menu: :main})
      {:noreply, result} = CustomHandler.handle_hangup(call)

      assert result.assigns.cleaned_up == true
    end
  end

  describe "pattern matching on call state" do
    defmodule StatefulHandler do
      use Parrot.InviteHandler

      def handle_invite(invite) do
        invite
        |> answer()
        |> assign(:retries, 0)
        |> play("welcome.wav")
      end

      def handle_dtmf(:timeout, %{assigns: %{retries: retries}} = call) when retries < 3 do
        call
        |> assign(:retries, retries + 1)
        |> play("please-try-again.wav")
      end

      def handle_dtmf(:timeout, call) do
        call
        |> play("goodbye.wav")
        |> hangup()
      end
    end

    test "increments retry counter on timeout" do
      call = Call.new(assigns: %{retries: 0})
      result = StatefulHandler.handle_dtmf(:timeout, call)

      assert result.assigns.retries == 1
      operations = Call.get_operations(result)
      assert [{:play, "please-try-again.wav", []}] = operations
    end

    test "hangs up after max retries" do
      call = Call.new(assigns: %{retries: 3})
      result = StatefulHandler.handle_dtmf(:timeout, call)

      operations = Call.get_operations(result)
      assert [{:play, "goodbye.wav", []}, {:hangup, []}] = operations
    end

    test "allows multiple retries before hanging up" do
      # First timeout
      call = Call.new(assigns: %{retries: 0})
      call = StatefulHandler.handle_dtmf(:timeout, call)
      assert call.assigns.retries == 1

      # Second timeout - need to clear operations for next iteration
      call = %{call | __operations__: []}
      call = StatefulHandler.handle_dtmf(:timeout, call)
      assert call.assigns.retries == 2

      # Third timeout
      call = %{call | __operations__: []}
      call = StatefulHandler.handle_dtmf(:timeout, call)
      assert call.assigns.retries == 3

      # Fourth timeout - should hangup
      call = %{call | __operations__: []}
      result = StatefulHandler.handle_dtmf(:timeout, call)
      operations = Call.get_operations(result)
      assert [{:play, "goodbye.wav", []}, {:hangup, []}] = operations
    end
  end

  describe "bridge completion handling" do
    defmodule BridgeHandler do
      use Parrot.InviteHandler

      def handle_invite(invite) do
        invite
        |> answer()
        |> bridge("sip:dest@somewhere")
      end

      def handle_bridge_complete(:answered, call) do
        {:noreply, %{call | assigns: Map.put(call.assigns, :bridged, true)}}
      end

      def handle_bridge_complete({:failed, :busy}, call) do
        call |> play("user-busy.wav")
      end

      def handle_bridge_complete({:failed, :no_answer}, call) do
        call |> play("no-answer.wav")
      end
    end

    test "handles successful bridge" do
      call = Call.new()
      {:noreply, result} = BridgeHandler.handle_bridge_complete(:answered, call)

      assert result.assigns.bridged == true
    end

    test "handles busy failure" do
      call = Call.new()
      result = BridgeHandler.handle_bridge_complete({:failed, :busy}, call)

      operations = Call.get_operations(result)
      assert [{:play, "user-busy.wav", []}] = operations
    end

    test "handles no_answer failure" do
      call = Call.new()
      result = BridgeHandler.handle_bridge_complete({:failed, :no_answer}, call)

      operations = Call.get_operations(result)
      assert [{:play, "no-answer.wav", []}] = operations
    end
  end

  describe "conference handling" do
    defmodule ConferenceHandler do
      use Parrot.InviteHandler

      def handle_invite(invite) do
        invite
        |> answer()
        |> assign(:room, "room-123")
      end

      def handle_conference_join(room, call) do
        {:noreply, %{call | assigns: Map.put(call.assigns, :in_conference, room)}}
      end

      def handle_conference_leave(room, reason, call) do
        {:noreply,
         %{call | assigns: Map.merge(call.assigns, %{left_room: room, leave_reason: reason})}}
      end
    end

    test "tracks conference join" do
      call = Call.new()
      {:noreply, result} = ConferenceHandler.handle_conference_join("room-123", call)

      assert result.assigns.in_conference == "room-123"
    end

    test "tracks conference leave with reason" do
      call = Call.new()
      {:noreply, result} = ConferenceHandler.handle_conference_leave("room-123", :kicked, call)

      assert result.assigns.left_room == "room-123"
      assert result.assigns.leave_reason == :kicked
    end
  end

  describe "recording handling" do
    defmodule RecordingHandler do
      use Parrot.InviteHandler

      def handle_invite(invite) do
        invite
        |> answer()
        |> record("voicemail.wav", max_duration: 60_000)
      end

      def handle_record_complete(filename, duration, call) do
        {:noreply,
         %{
           call
           | assigns:
               Map.merge(call.assigns, %{
                 recording: filename,
                 duration: duration
               })
         }}
      end
    end

    test "tracks recording completion with metadata" do
      call = Call.new()
      {:noreply, result} = RecordingHandler.handle_record_complete("voicemail.wav", 30_000, call)

      assert result.assigns.recording == "voicemail.wav"
      assert result.assigns.duration == 30_000
    end
  end

  describe "media fork handling" do
    defmodule MediaForkHandler do
      use Parrot.InviteHandler

      def handle_invite(invite) do
        invite
        |> answer()
      end

      def handle_fork_media_connected(fork_id, call) do
        {:noreply, %{call | assigns: Map.put(call.assigns, :active_fork, fork_id)}}
      end

      def handle_fork_media_error(fork_id, reason, call) do
        new_assigns =
          call.assigns
          |> Map.put(:fork_error, {fork_id, reason})
          |> Map.put(:fork_error_count, Map.get(call.assigns, :fork_error_count, 0) + 1)

        {:noreply, %{call | assigns: new_assigns}}
      end
    end

    defmodule MediaForkRetryHandler do
      use Parrot.InviteHandler

      def handle_invite(invite) do
        invite |> answer()
      end

      # Retry with backup service on first failure
      def handle_fork_media_error(_fork_id, _reason, %{assigns: %{retry_attempted: true}} = call) do
        # Already retried, give up
        {:noreply, %{call | assigns: Map.put(call.assigns, :fork_failed, true)}}
      end

      def handle_fork_media_error(_fork_id, _reason, call) do
        # First failure - retry with backup
        call
        |> assign(:retry_attempted, true)
        |> fork_media("wss://backup-transcription.example.com/audio")
      end
    end

    test "tracks media fork connection" do
      call = Call.new()

      {:noreply, result} =
        MediaForkHandler.handle_fork_media_connected("fork-abc123", call)

      assert result.assigns.active_fork == "fork-abc123"
    end

    test "tracks media fork errors" do
      call = Call.new()

      {:noreply, result} =
        MediaForkHandler.handle_fork_media_error("fork-abc123", :connection_refused, call)

      assert result.assigns.fork_error == {"fork-abc123", :connection_refused}
      assert result.assigns.fork_error_count == 1
    end

    test "accumulates fork error count across multiple errors" do
      call = Call.new(assigns: %{fork_error_count: 2})

      {:noreply, result} =
        MediaForkHandler.handle_fork_media_error("fork-xyz", :timeout, call)

      assert result.assigns.fork_error_count == 3
    end

    test "handle_fork_media_error can queue retry operations" do
      call = Call.new()

      result = MediaForkRetryHandler.handle_fork_media_error("fork-abc123", :timeout, call)

      # First failure should retry
      assert result.assigns.retry_attempted == true
      operations = Call.get_operations(result)
      assert [{:fork_media, "wss://backup-transcription.example.com/audio", []}] = operations
    end

    test "handle_fork_media_error stops retrying after max attempts" do
      call = Call.new(assigns: %{retry_attempted: true})

      {:noreply, result} =
        MediaForkRetryHandler.handle_fork_media_error("fork-abc123", :timeout, call)

      assert result.assigns.fork_failed == true
    end

    test "handle_fork_media_error receives various error types" do
      call = Call.new()

      errors = [
        :connection_refused,
        :timeout,
        {:ws_error, 1006},
        {:http_error, 503},
        :dns_resolution_failed,
        {:network_error, :econnrefused}
      ]

      for error <- errors do
        {:noreply, result} = MediaForkHandler.handle_fork_media_error("fork-1", error, call)
        assert result.assigns.fork_error == {"fork-1", error}
      end
    end
  end

  describe "TTS error handling (T042, FR-017, FR-019)" do
    defmodule TTSErrorHandler do
      use Parrot.InviteHandler

      def handle_invite(invite) do
        invite
        |> answer()
      end

      # Custom error handler that tracks errors in assigns
      # Signature: handle_tts_error(text, error, call) per quickstart.md
      def handle_tts_error(text, error, call) do
        %{call | assigns: Map.merge(call.assigns, %{
          tts_error: error,
          failed_text: text,
          error_count: Map.get(call.assigns, :error_count, 0) + 1
        })}
      end
    end

    defmodule TTSErrorWithFallbackHandler do
      use Parrot.InviteHandler

      def handle_invite(invite) do
        invite
        |> answer()
      end

      # Custom handler that plays a fallback audio file on TTS error
      def handle_tts_error(_text, _error, call) do
        call
        |> play("error-fallback.wav")
      end
    end

    defmodule TTSErrorRetryHandler do
      use Parrot.InviteHandler

      def handle_invite(invite) do
        invite
        |> answer()
      end

      # Handler that retries with backup provider (FR-019 scenario)
      def handle_tts_error(_text, _error, %{assigns: %{tts_retry: true}} = call) do
        # Already retried, give up and play fallback
        call |> play("sorry-technical-difficulties.wav")
      end

      def handle_tts_error(text, _error, call) do
        # First failure - retry with backup provider
        call
        |> assign(:tts_retry, true)
        |> assign(:retry_text, text)
      end
    end

    test "custom handler can track TTS errors in assigns" do
      call = Call.new()
      result = TTSErrorHandler.handle_tts_error("Hello world", :api_timeout, call)

      assert result.assigns.tts_error == :api_timeout
      assert result.assigns.failed_text == "Hello world"
      assert result.assigns.error_count == 1
    end

    test "custom handler accumulates error count across multiple errors" do
      call = Call.new(assigns: %{error_count: 2})
      result = TTSErrorHandler.handle_tts_error("Test", :rate_limited, call)

      assert result.assigns.error_count == 3
    end

    test "custom handler can queue fallback audio playback on error (FR-019)" do
      call = Call.new()
      result = TTSErrorWithFallbackHandler.handle_tts_error("Failed text", :synthesis_failed, call)

      operations = Call.get_operations(result)
      assert [{:play, "error-fallback.wav", []}] = operations
    end

    test "handle_tts_error is defoverridable" do
      # Verify that a module using InviteHandler can override handle_tts_error
      # This is implicitly tested by TTSErrorHandler above working correctly
      call = Call.new()
      # MinimalHandler uses default, TTSErrorHandler overrides
      minimal_result = Parrot.InviteHandlerTest.MinimalHandler.handle_tts_error("text", :error, call)
      custom_result = TTSErrorHandler.handle_tts_error("text", :error, call)

      # Default returns {:noreply, call}
      assert minimal_result == {:noreply, call}
      # Custom tracks the error and returns modified call
      assert custom_result.assigns[:tts_error] == :error
    end

    test "callback receives text that failed, error reason, and call struct (T042)" do
      call = Call.new(assigns: %{session_id: "test-123"})
      result = TTSErrorHandler.handle_tts_error("Welcome to Parrot", {:provider_error, "Rate limit"}, call)

      # Verify all three arguments are accessible
      assert result.assigns.failed_text == "Welcome to Parrot"
      assert result.assigns.tts_error == {:provider_error, "Rate limit"}
      # Original assigns preserved
      assert result.assigns.session_id == "test-123"
    end

    test "custom handler can implement retry logic (FR-019)" do
      call = Call.new()

      # First failure - should mark for retry
      result1 = TTSErrorRetryHandler.handle_tts_error("Original text", :api_timeout, call)
      assert result1.assigns.tts_retry == true
      assert result1.assigns.retry_text == "Original text"

      # Second failure - should play fallback
      result2 = TTSErrorRetryHandler.handle_tts_error("Different text", :api_timeout, result1)
      operations = Call.get_operations(result2)
      assert [{:play, "sorry-technical-difficulties.wav", []}] = operations
    end

    test "custom handler receives different error types" do
      call = Call.new()

      # Test various error types that might come from synthesizer
      errors = [
        :api_timeout,
        :synthesis_failed,
        :rate_limited,
        {:provider_error, "Service unavailable"},
        {:network_error, :econnrefused},
        {:http_error, 503}
      ]

      for error <- errors do
        result = TTSErrorHandler.handle_tts_error("test", error, call)
        assert result.assigns.tts_error == error
      end
    end
  end

  describe "prompt complete handling" do
    defmodule PromptHandler do
      use Parrot.InviteHandler

      def handle_invite(invite) do
        # Note: prompt/3 DSL is blocked pending MediaSession DTMF support
        # This test only verifies the callback handling
        invite
        |> answer()
        |> play("enter-pin.wav")
      end

      def handle_prompt_complete("enter-pin.wav", digits, call) do
        {:noreply, %{call | assigns: Map.put(call.assigns, :pin, digits)}}
      end

      def handle_prompt_complete(_filename, _digits, call) do
        {:noreply, call}
      end
    end

    test "captures collected digits from prompt callback" do
      call = Call.new()
      {:noreply, result} = PromptHandler.handle_prompt_complete("enter-pin.wav", "1234", call)

      assert result.assigns.pin == "1234"
    end
  end

  # ===========================================================================
  # Media Event Callbacks (US4: Media Event Observability - T038, T039, T040)
  # ===========================================================================

  describe "media event callbacks (US4, FR-010, FR-011)" do
    defmodule MediaEventTrackingHandler do
      use Parrot.InviteHandler

      def handle_invite(invite) do
        invite
        |> answer()
      end

      # Override handle_media_started to track the event
      def handle_media_started(call) do
        # Track media start time in assigns for observability
        start_time = System.monotonic_time(:millisecond)
        {:noreply, %{call | assigns: Map.put(call.assigns, :media_started_at, start_time)}}
      end

      # Override handle_media_stopped to track the event and reason
      def handle_media_stopped(reason, call) do
        stop_time = System.monotonic_time(:millisecond)
        duration = calculate_duration(call.assigns[:media_started_at], stop_time)

        new_assigns =
          call.assigns
          |> Map.put(:media_stopped_at, stop_time)
          |> Map.put(:media_stop_reason, reason)
          |> Map.put(:media_duration, duration)

        {:noreply, %{call | assigns: new_assigns}}
      end

      defp calculate_duration(nil, _stop), do: nil
      defp calculate_duration(start, stop), do: stop - start
    end

    defmodule MediaEventCleanupHandler do
      use Parrot.InviteHandler

      def handle_invite(invite) do
        invite |> answer()
      end

      # Handler that performs cleanup when media stops
      def handle_media_stopped(:terminated, call) do
        # Perform cleanup on terminated
        {:noreply, %{call | assigns: Map.put(call.assigns, :cleanup_performed, true)}}
      end

      def handle_media_stopped(_reason, call) do
        {:noreply, call}
      end
    end

    test "handle_media_started/1 receives call struct and can track media start" do
      call = Call.new(assigns: %{session_id: "test-123"})
      {:noreply, result} = MediaEventTrackingHandler.handle_media_started(call)

      # Should have media_started_at timestamp
      assert result.assigns[:media_started_at] != nil
      # Original assigns preserved
      assert result.assigns[:session_id] == "test-123"
    end

    test "handle_media_stopped/2 receives reason and call struct" do
      call = Call.new(assigns: %{media_started_at: System.monotonic_time(:millisecond) - 5000})
      {:noreply, result} = MediaEventTrackingHandler.handle_media_stopped(:normal, call)

      # Should track stop time and reason
      assert result.assigns[:media_stopped_at] != nil
      assert result.assigns[:media_stop_reason] == :normal
    end

    test "handle_media_stopped/2 can calculate call duration" do
      start_time = System.monotonic_time(:millisecond) - 5000
      call = Call.new(assigns: %{media_started_at: start_time})
      {:noreply, result} = MediaEventTrackingHandler.handle_media_stopped(:normal, call)

      # Duration should be approximately 5000ms (with some tolerance for test execution)
      assert result.assigns[:media_duration] != nil
      assert result.assigns[:media_duration] >= 4900
    end

    test "handle_media_stopped/2 can pattern match on reason for different behaviors" do
      call = Call.new()

      {:noreply, result1} = MediaEventCleanupHandler.handle_media_stopped(:terminated, call)
      assert result1.assigns[:cleanup_performed] == true

      {:noreply, result2} = MediaEventCleanupHandler.handle_media_stopped(:normal, call)
      assert result2.assigns[:cleanup_performed] == nil
    end

    test "handle_media_started/1 is defoverridable" do
      call = Call.new()

      # MinimalHandler uses default implementation (from "use Parrot.InviteHandler" describe block)
      minimal_result =
        Parrot.InviteHandlerTest.MinimalHandler.handle_media_started(call)

      assert minimal_result == {:noreply, call}

      # MediaEventTrackingHandler overrides it
      {:noreply, custom_result} = MediaEventTrackingHandler.handle_media_started(call)
      assert custom_result.assigns[:media_started_at] != nil
    end

    test "handle_media_stopped/2 is defoverridable" do
      call = Call.new()

      # MinimalHandler uses default implementation (from "use Parrot.InviteHandler" describe block)
      minimal_result =
        Parrot.InviteHandlerTest.MinimalHandler.handle_media_stopped(:normal, call)

      assert minimal_result == {:noreply, call}

      # MediaEventTrackingHandler overrides it
      {:noreply, custom_result} = MediaEventTrackingHandler.handle_media_stopped(:normal, call)
      assert custom_result.assigns[:media_stop_reason] == :normal
    end

    test "handlers can track call duration using both callbacks together" do
      call = Call.new()

      # Simulate media started
      {:noreply, call_with_start} = MediaEventTrackingHandler.handle_media_started(call)
      assert call_with_start.assigns[:media_started_at] != nil

      # Simulate some time passing (mock by adjusting start time)
      call_after_time = %{
        call_with_start
        | assigns:
            Map.put(
              call_with_start.assigns,
              :media_started_at,
              System.monotonic_time(:millisecond) - 10_000
            )
      }

      # Simulate media stopped
      {:noreply, call_with_stop} =
        MediaEventTrackingHandler.handle_media_stopped(:normal, call_after_time)

      assert call_with_stop.assigns[:media_duration] >= 9900
      assert call_with_stop.assigns[:media_stop_reason] == :normal
    end
  end

  describe "fork complete handling" do
    defmodule ForkHandler do
      use Parrot.InviteHandler

      def handle_invite(invite) do
        destinations = [
          {"sip:alice@device1", []},
          {"sip:alice@device2", []}
        ]

        invite
        |> answer()
        |> fork(destinations, strategy: :first_answer)
      end

      def handle_fork_complete({:answered, destination}, call) do
        {:noreply, %{call | assigns: Map.put(call.assigns, :answered_by, destination)}}
      end

      def handle_fork_complete({:failed, _reason}, call) do
        call |> play("all-lines-busy.wav")
      end
    end

    test "tracks which destination answered" do
      call = Call.new()

      {:noreply, result} =
        ForkHandler.handle_fork_complete({:answered, "sip:alice@device2"}, call)

      assert result.assigns.answered_by == "sip:alice@device2"
    end

    test "handles all destinations failing" do
      call = Call.new()
      result = ForkHandler.handle_fork_complete({:failed, :all_busy}, call)

      operations = Call.get_operations(result)
      assert [{:play, "all-lines-busy.wav", []}] = operations
    end
  end

  # ===========================================================================
  # Leg Event Callbacks (B2BUA T07: handle_leg_event/3)
  # ===========================================================================

  describe "handle_leg_event/3 callback (T07)" do
    test "defines handle_leg_event/3 callback in behaviour" do
      callbacks = Parrot.InviteHandler.behaviour_info(:callbacks)
      assert {:handle_leg_event, 3} in callbacks
    end
  end

  describe "use Parrot.InviteHandler - handle_leg_event/3 default" do
    test "provides default handle_leg_event/3 implementation returning {:ok, call}" do
      call = Call.new()
      result = Parrot.InviteHandlerTest.MinimalHandler.handle_leg_event(call, :b_leg, :ringing)
      assert {:ok, ^call} = result
    end

    test "default implementation handles all event types gracefully" do
      call = Call.new()

      # Test various event types from design doc
      events = [
        :trying,
        :ringing,
        {:early_media, "v=0\r\n..."},
        {:answered, "v=0\r\n..."},
        {:failed, :busy},
        :bye,
        :cancelled,
        :held,
        :resumed,
        {:refer_requested, "sip:transfer@example.com"},
        {:transfer_complete, :c_leg},
        {:transfer_failed, :no_answer}
      ]

      for event <- events do
        result = Parrot.InviteHandlerTest.MinimalHandler.handle_leg_event(call, :b_leg, event)
        assert {:ok, ^call} = result, "Expected {:ok, call} for event #{inspect(event)}"
      end
    end
  end

  describe "overriding handle_leg_event/3" do
    defmodule LegEventHandler do
      use Parrot.InviteHandler

      def handle_invite(invite) do
        invite
        |> answer()
        |> bridge("sip:agent@pbx.local")
      end

      # Track ringing events
      def handle_leg_event(call, leg_id, :ringing) do
        new_assigns = Map.put(call.assigns, :ringing_leg, leg_id)
        {:ok, %{call | assigns: new_assigns}}
      end

      # Handle answered - could bridge media
      def handle_leg_event(call, leg_id, {:answered, sdp}) do
        new_assigns =
          call.assigns
          |> Map.put(:answered_leg, leg_id)
          |> Map.put(:answered_sdp, sdp)

        {:ok, %{call | assigns: new_assigns}}
      end

      # Handle failed - play error message and hangup
      def handle_leg_event(call, _leg_id, {:failed, _reason}) do
        {:ok, call |> play("unavailable.wav") |> hangup()}
      end

      # Handle BYE - hangup remaining legs
      def handle_leg_event(call, _leg_id, :bye) do
        {:ok, call |> hangup()}
      end

      # Default fallback
      def handle_leg_event(call, _leg_id, _event) do
        {:ok, call}
      end
    end

    test "can override to track ringing events" do
      call = Call.new()
      {:ok, result} = LegEventHandler.handle_leg_event(call, :b_leg, :ringing)

      assert result.assigns.ringing_leg == :b_leg
    end

    test "can override to handle answered event with SDP" do
      call = Call.new()
      sdp = "v=0\r\no=- 123 456 IN IP4 192.168.1.1\r\n"
      {:ok, result} = LegEventHandler.handle_leg_event(call, :b_leg, {:answered, sdp})

      assert result.assigns.answered_leg == :b_leg
      assert result.assigns.answered_sdp == sdp
    end

    test "can override to queue operations on failure" do
      call = Call.new()
      {:ok, result} = LegEventHandler.handle_leg_event(call, :b_leg, {:failed, :busy})

      operations = Call.get_operations(result)
      assert [{:play, "unavailable.wav", []}, {:hangup, []}] = operations
    end

    test "can override to hangup on BYE" do
      call = Call.new()
      {:ok, result} = LegEventHandler.handle_leg_event(call, :b_leg, :bye)

      operations = Call.get_operations(result)
      assert [{:hangup, []}] = operations
    end

    test "handle_leg_event/3 is defoverridable" do
      call = Call.new()

      # MinimalHandler uses default
      minimal_result = Parrot.InviteHandlerTest.MinimalHandler.handle_leg_event(call, :b_leg, :ringing)
      assert minimal_result == {:ok, call}

      # LegEventHandler overrides it
      {:ok, custom_result} = LegEventHandler.handle_leg_event(call, :b_leg, :ringing)
      assert custom_result.assigns[:ringing_leg] == :b_leg
    end
  end

  describe "handle_leg_event/3 bridge return value" do
    defmodule BridgingLegEventHandler do
      use Parrot.InviteHandler

      def handle_invite(invite) do
        invite
        |> answer()
        |> fork(["sip:a@x", "sip:b@x"], strategy: :simultaneous)
      end

      # When a leg answers, bridge it to A-leg
      def handle_leg_event(call, leg_id, {:answered, _sdp}) do
        {:bridge, leg_id, call}
      end

      def handle_leg_event(call, _leg_id, _event) do
        {:ok, call}
      end
    end

    test "can return {:bridge, leg_id, call} to connect leg to A-leg" do
      call = Call.new()
      result = BridgingLegEventHandler.handle_leg_event(call, :b_leg, {:answered, "v=0\r\n"})

      assert {:bridge, :b_leg, ^call} = result
    end

    test "bridge return value preserves call struct" do
      call = Call.new(assigns: %{session_id: "test-123"})
      {:bridge, _leg_id, returned_call} =
        BridgingLegEventHandler.handle_leg_event(call, :b_leg, {:answered, "v=0\r\n"})

      assert returned_call.assigns.session_id == "test-123"
    end
  end

  describe "handle_leg_event/3 reject_refer return value" do
    defmodule ReferRejectingHandler do
      use Parrot.InviteHandler

      def handle_invite(invite) do
        invite |> answer()
      end

      # Reject transfer requests from certain legs
      def handle_leg_event(call, :untrusted_leg, {:refer_requested, _uri}) do
        {:reject_refer, :forbidden, call}
      end

      # Allow other transfer requests
      def handle_leg_event(call, _leg_id, {:refer_requested, uri}) do
        new_assigns = Map.put(call.assigns, :transfer_requested_to, uri)
        {:ok, %{call | assigns: new_assigns}}
      end

      def handle_leg_event(call, _leg_id, _event) do
        {:ok, call}
      end
    end

    test "can return {:reject_refer, reason, call} to reject REFER request" do
      call = Call.new()
      result = ReferRejectingHandler.handle_leg_event(call, :untrusted_leg, {:refer_requested, "sip:target@x"})

      assert {:reject_refer, :forbidden, ^call} = result
    end

    test "can allow REFER requests from trusted legs" do
      call = Call.new()
      {:ok, result} =
        ReferRejectingHandler.handle_leg_event(call, :trusted_leg, {:refer_requested, "sip:target@x"})

      assert result.assigns.transfer_requested_to == "sip:target@x"
    end
  end

  describe "handle_leg_event/3 with all leg events from design doc" do
    defmodule ComprehensiveLegEventHandler do
      use Parrot.InviteHandler

      def handle_invite(invite), do: invite |> answer()

      def handle_leg_event(call, leg_id, :trying) do
        {:ok, %{call | assigns: Map.put(call.assigns, :event, {:trying, leg_id})}}
      end

      def handle_leg_event(call, leg_id, :ringing) do
        {:ok, %{call | assigns: Map.put(call.assigns, :event, {:ringing, leg_id})}}
      end

      def handle_leg_event(call, leg_id, {:early_media, sdp}) do
        {:ok, %{call | assigns: Map.put(call.assigns, :event, {:early_media, leg_id, sdp})}}
      end

      def handle_leg_event(call, leg_id, {:answered, sdp}) do
        {:ok, %{call | assigns: Map.put(call.assigns, :event, {:answered, leg_id, sdp})}}
      end

      def handle_leg_event(call, leg_id, {:failed, reason}) do
        {:ok, %{call | assigns: Map.put(call.assigns, :event, {:failed, leg_id, reason})}}
      end

      def handle_leg_event(call, leg_id, :bye) do
        {:ok, %{call | assigns: Map.put(call.assigns, :event, {:bye, leg_id})}}
      end

      def handle_leg_event(call, leg_id, :cancelled) do
        {:ok, %{call | assigns: Map.put(call.assigns, :event, {:cancelled, leg_id})}}
      end

      def handle_leg_event(call, leg_id, :held) do
        {:ok, %{call | assigns: Map.put(call.assigns, :event, {:held, leg_id})}}
      end

      def handle_leg_event(call, leg_id, :resumed) do
        {:ok, %{call | assigns: Map.put(call.assigns, :event, {:resumed, leg_id})}}
      end

      def handle_leg_event(call, leg_id, {:refer_requested, uri}) do
        {:ok, %{call | assigns: Map.put(call.assigns, :event, {:refer_requested, leg_id, uri})}}
      end

      def handle_leg_event(call, leg_id, {:transfer_complete, new_leg_id}) do
        {:ok, %{call | assigns: Map.put(call.assigns, :event, {:transfer_complete, leg_id, new_leg_id})}}
      end

      def handle_leg_event(call, leg_id, {:transfer_failed, reason}) do
        {:ok, %{call | assigns: Map.put(call.assigns, :event, {:transfer_failed, leg_id, reason})}}
      end
    end

    test "handles :trying event" do
      call = Call.new()
      {:ok, result} = ComprehensiveLegEventHandler.handle_leg_event(call, :b_leg, :trying)
      assert result.assigns.event == {:trying, :b_leg}
    end

    test "handles :ringing event" do
      call = Call.new()
      {:ok, result} = ComprehensiveLegEventHandler.handle_leg_event(call, :b_leg, :ringing)
      assert result.assigns.event == {:ringing, :b_leg}
    end

    test "handles {:early_media, sdp} event" do
      call = Call.new()
      sdp = "v=0\r\n"
      {:ok, result} = ComprehensiveLegEventHandler.handle_leg_event(call, :b_leg, {:early_media, sdp})
      assert result.assigns.event == {:early_media, :b_leg, sdp}
    end

    test "handles {:answered, sdp} event" do
      call = Call.new()
      sdp = "v=0\r\n"
      {:ok, result} = ComprehensiveLegEventHandler.handle_leg_event(call, :b_leg, {:answered, sdp})
      assert result.assigns.event == {:answered, :b_leg, sdp}
    end

    test "handles {:failed, reason} event" do
      call = Call.new()
      {:ok, result} = ComprehensiveLegEventHandler.handle_leg_event(call, :b_leg, {:failed, :busy})
      assert result.assigns.event == {:failed, :b_leg, :busy}
    end

    test "handles :bye event" do
      call = Call.new()
      {:ok, result} = ComprehensiveLegEventHandler.handle_leg_event(call, :b_leg, :bye)
      assert result.assigns.event == {:bye, :b_leg}
    end

    test "handles :cancelled event" do
      call = Call.new()
      {:ok, result} = ComprehensiveLegEventHandler.handle_leg_event(call, :b_leg, :cancelled)
      assert result.assigns.event == {:cancelled, :b_leg}
    end

    test "handles :held event" do
      call = Call.new()
      {:ok, result} = ComprehensiveLegEventHandler.handle_leg_event(call, :b_leg, :held)
      assert result.assigns.event == {:held, :b_leg}
    end

    test "handles :resumed event" do
      call = Call.new()
      {:ok, result} = ComprehensiveLegEventHandler.handle_leg_event(call, :b_leg, :resumed)
      assert result.assigns.event == {:resumed, :b_leg}
    end

    test "handles {:refer_requested, uri} event" do
      call = Call.new()
      uri = "sip:transfer@example.com"
      {:ok, result} = ComprehensiveLegEventHandler.handle_leg_event(call, :b_leg, {:refer_requested, uri})
      assert result.assigns.event == {:refer_requested, :b_leg, uri}
    end

    test "handles {:transfer_complete, new_leg_id} event" do
      call = Call.new()
      {:ok, result} = ComprehensiveLegEventHandler.handle_leg_event(call, :b_leg, {:transfer_complete, :c_leg})
      assert result.assigns.event == {:transfer_complete, :b_leg, :c_leg}
    end

    test "handles {:transfer_failed, reason} event" do
      call = Call.new()
      {:ok, result} = ComprehensiveLegEventHandler.handle_leg_event(call, :b_leg, {:transfer_failed, :no_answer})
      assert result.assigns.event == {:transfer_failed, :b_leg, :no_answer}
    end
  end

  describe "handle_leg_event/3 leg_id types" do
    test "accepts atom leg IDs" do
      call = Call.new()
      result = Parrot.InviteHandlerTest.MinimalHandler.handle_leg_event(call, :a_leg, :ringing)
      assert {:ok, _} = result

      result = Parrot.InviteHandlerTest.MinimalHandler.handle_leg_event(call, :b_leg, :ringing)
      assert {:ok, _} = result
    end

    test "accepts string leg IDs" do
      call = Call.new()
      result = Parrot.InviteHandlerTest.MinimalHandler.handle_leg_event(call, "custom-leg-123", :ringing)
      assert {:ok, _} = result
    end
  end

  # ===========================================================================
  # Early Media Callback (183 Session Progress)
  # ===========================================================================

  describe "handle_early_media/2 callback" do
    defmodule EarlyMediaHandler do
      use Parrot.InviteHandler

      def handle_invite(invite) do
        invite |> answer()
      end

      # Override to track early media
      def handle_early_media(response, call) do
        new_assigns =
          call.assigns
          |> Map.put(:early_media_received, true)
          |> Map.put(:early_media_sdp, response[:body])

        {:noreply, %{call | assigns: new_assigns}}
      end
    end

    defmodule EarlyMediaStopRingbackHandler do
      use Parrot.InviteHandler

      def handle_invite(invite) do
        invite |> answer()
      end

      # Stop local ringback when early media is received
      def handle_early_media(_response, call) do
        call
        |> assign(:ringback_stopped, true)
      end
    end

    test "receives 183 response and call struct" do
      call = Call.new(assigns: %{session_id: "test-123"})
      response = %{status: 183, body: "v=0\r\no=- 123 456 IN IP4 192.168.1.1\r\n"}

      {:noreply, result} = EarlyMediaHandler.handle_early_media(response, call)

      assert result.assigns.early_media_received == true
      assert result.assigns.early_media_sdp == response[:body]
      assert result.assigns.session_id == "test-123"
    end

    test "can return Call struct with operations (not wrapped in {:noreply, _})" do
      call = Call.new()
      response = %{status: 183, body: "v=0\r\n"}

      result = EarlyMediaStopRingbackHandler.handle_early_media(response, call)

      # Can return just the call struct (not wrapped)
      assert result.assigns.ringback_stopped == true
    end

    test "handle_early_media/2 is defoverridable" do
      call = Call.new()
      response = %{status: 183, body: "v=0\r\n"}

      # MinimalHandler uses default
      minimal_result = Parrot.InviteHandlerTest.MinimalHandler.handle_early_media(response, call)
      assert minimal_result == {:noreply, call}

      # EarlyMediaHandler overrides it
      {:noreply, custom_result} = EarlyMediaHandler.handle_early_media(response, call)
      assert custom_result.assigns[:early_media_received] == true
    end
  end

  # ===========================================================================
  # RFC 3311 UPDATE Callbacks
  # ===========================================================================

  describe "UPDATE callbacks (RFC 3311)" do
    defmodule UpdateHandler do
      use Parrot.InviteHandler

      def handle_invite(invite) do
        invite |> answer()
      end

      # Accept UPDATE requests and track the new SDP
      def handle_update(request, call) do
        new_assigns = Map.put(call.assigns, :received_update_sdp, request[:body])
        {:noreply, %{call | assigns: new_assigns}}
      end

      # Track successful UPDATE completion
      def handle_update_complete(response, call) do
        new_assigns =
          call.assigns
          |> Map.put(:update_complete, true)
          |> Map.put(:update_response_sdp, response[:body])

        {:noreply, %{call | assigns: new_assigns}}
      end

      # Track UPDATE failures
      def handle_update_failed(status, response, call) do
        new_assigns =
          call.assigns
          |> Map.put(:update_failed, true)
          |> Map.put(:update_failure_status, status)
          |> Map.put(:update_failure_reason, response[:reason])

        {:noreply, %{call | assigns: new_assigns}}
      end
    end

    defmodule UpdateRejectHandler do
      use Parrot.InviteHandler

      def handle_invite(invite) do
        invite |> answer()
      end

      # Reject UPDATE requests if not in correct state
      def handle_update(_request, %{assigns: %{hold_active: true}} = call) do
        {:reject, 491, call}  # Request Pending
      end

      # Accept other UPDATE requests
      def handle_update(request, call) do
        new_assigns = Map.put(call.assigns, :update_accepted, request[:body])
        {:noreply, %{call | assigns: new_assigns}}
      end
    end

    test "handle_update/2 receives request map and call struct" do
      call = Call.new(assigns: %{session_id: "test-123"})
      request = %{method: :update, body: "v=0\r\no=- 123 456 IN IP4 192.168.1.1\r\n"}

      {:noreply, result} = UpdateHandler.handle_update(request, call)

      assert result.assigns.received_update_sdp == request[:body]
      assert result.assigns.session_id == "test-123"
    end

    test "handle_update/2 can return {:reject, status, call} to reject the UPDATE" do
      call = Call.new(assigns: %{hold_active: true})
      request = %{method: :update, body: "v=0\r\n"}

      result = UpdateRejectHandler.handle_update(request, call)

      assert {:reject, 491, ^call} = result
    end

    test "handle_update/2 can accept UPDATE with {:noreply, call}" do
      call = Call.new()
      request = %{method: :update, body: "v=0\r\n"}

      {:noreply, result} = UpdateRejectHandler.handle_update(request, call)

      assert result.assigns.update_accepted == "v=0\r\n"
    end

    test "handle_update_complete/2 receives response and tracks success" do
      call = Call.new(assigns: %{session_id: "test-123"})
      response = %{status: 200, body: "v=0\r\no=- 456 789 IN IP4 192.168.1.2\r\n"}

      {:noreply, result} = UpdateHandler.handle_update_complete(response, call)

      assert result.assigns.update_complete == true
      assert result.assigns.update_response_sdp == response[:body]
      assert result.assigns.session_id == "test-123"
    end

    test "handle_update_failed/3 receives status, response, and call" do
      call = Call.new(assigns: %{session_id: "test-123"})
      response = %{status: 488, reason: "Not Acceptable Here"}

      {:noreply, result} = UpdateHandler.handle_update_failed(488, response, call)

      assert result.assigns.update_failed == true
      assert result.assigns.update_failure_status == 488
      assert result.assigns.update_failure_reason == "Not Acceptable Here"
      assert result.assigns.session_id == "test-123"
    end

    test "handle_update/2 is defoverridable" do
      call = Call.new()
      request = %{method: :update, body: "v=0\r\n"}

      # MinimalHandler uses default
      minimal_result = Parrot.InviteHandlerTest.MinimalHandler.handle_update(request, call)
      assert minimal_result == {:noreply, call}

      # UpdateHandler overrides it
      {:noreply, custom_result} = UpdateHandler.handle_update(request, call)
      assert custom_result.assigns[:received_update_sdp] == "v=0\r\n"
    end

    test "handle_update_complete/2 is defoverridable" do
      call = Call.new()
      response = %{status: 200, body: "v=0\r\n"}

      # MinimalHandler uses default
      minimal_result = Parrot.InviteHandlerTest.MinimalHandler.handle_update_complete(response, call)
      assert minimal_result == {:noreply, call}

      # UpdateHandler overrides it
      {:noreply, custom_result} = UpdateHandler.handle_update_complete(response, call)
      assert custom_result.assigns[:update_complete] == true
    end

    test "handle_update_failed/3 is defoverridable" do
      call = Call.new()
      response = %{status: 488, reason: "Not Acceptable Here"}

      # MinimalHandler uses default
      minimal_result = Parrot.InviteHandlerTest.MinimalHandler.handle_update_failed(488, response, call)
      assert minimal_result == {:noreply, call}

      # UpdateHandler overrides it
      {:noreply, custom_result} = UpdateHandler.handle_update_failed(488, response, call)
      assert custom_result.assigns[:update_failed] == true
    end

    test "handle_update_failed/3 handles various failure status codes" do
      call = Call.new()

      # Common UPDATE failure codes per RFC 3311
      failure_scenarios = [
        {488, "Not Acceptable Here"},
        {491, "Request Pending"},
        {500, "Server Internal Error"},
        {503, "Service Unavailable"}
      ]

      for {status, reason} <- failure_scenarios do
        response = %{status: status, reason: reason}
        {:noreply, result} = UpdateHandler.handle_update_failed(status, response, call)
        assert result.assigns.update_failure_status == status
        assert result.assigns.update_failure_reason == reason
      end
    end
  end
end
