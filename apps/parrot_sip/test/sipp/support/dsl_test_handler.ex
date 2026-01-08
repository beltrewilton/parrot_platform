defmodule SippTest.DSLTestHandler do
  @moduledoc """
  Documentation module showing how Parrot.InviteHandler would be used for DSL tests.

  This module demonstrates the intended usage pattern for the Parrot DSL when
  implementing call handling logic. The actual DSL tests use SippTest.TestHandler
  because parrot_sip doesn't depend on the parrot app directly.

  ## Intended Usage Pattern

  When the full Parrot application is used, implement handlers like this:

      defmodule MyApp.IVRHandler do
        use Parrot.InviteHandler

        def handle_invite(call) do
          call
          |> answer()
          |> assign(:menu, :main)
          |> play("welcome.wav")
        end

        def handle_dtmf("1", %{assigns: %{menu: :main}} = call) do
          call
          |> assign(:menu, :sales)
          |> bridge("sip:sales@internal")
        end

        def handle_dtmf("2", %{assigns: %{menu: :main}} = call) do
          call
          |> assign(:menu, :support)
          |> bridge("sip:support@internal")
        end

        def handle_dtmf(_digit, call) do
          call |> play("invalid-option.wav")
        end
      end

  ## Supported Behaviors (via assigns)

  - `:answer` - Answer the call with 200 OK
  - `:reject` - Reject the call (use `reject_code` assign for status code)
  - `:play_and_hangup` - Answer, play audio, then hangup
  - `:bridge` - Answer and bridge to another endpoint (use `bridge_target` assign)
  - `:fork` - Answer and fork to multiple endpoints (use `fork_targets` assign)
  - `:dtmf_response` - Answer and respond to DTMF events

  ## DSL Operations Available

  ### Signaling
  - `answer/1`, `answer/2` - Answer the call
  - `reject/2` - Reject with status code
  - `hangup/1` - Hang up the call

  ### State
  - `assign/3` - Store per-call state

  ### Playback
  - `play/2`, `play/3` - Play audio file(s)

  ### Recording
  - `record/2`, `record/3` - Start recording
  - `stop_record/1` - Stop recording

  ### DTMF
  - `collect_dtmf/2` - Collect DTMF digits
  - `prompt/3` - Play audio and collect DTMF

  ### Bridging
  - `bridge/2`, `bridge/3` - Bridge to another endpoint
  - `fork/2`, `fork/3` - Fork call to multiple endpoints
  """

  # Note: This module is documentation only.
  # The actual tests use SippTest.TestHandler from test/support/test_handler.ex
  # because parrot_sip tests can't directly access modules from the parrot app.
  #
  # When building applications with Parrot, you would:
  # 1. Depend on the full :parrot application
  # 2. Use `use Parrot.InviteHandler` in your handler modules
  # 3. Implement callbacks like handle_invite/1, handle_dtmf/2, etc.
  #
  # See apps/parrot/test/parrot/invite_handler_test.exs for full examples.
end
