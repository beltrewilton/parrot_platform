# Test script for DSL MediaHandler message patterns
# Run with: LOG_LEVEL=debug mix run scripts/dev/test_media_handler.exs
#
# This script demonstrates:
# - How MediaHandler receives messages like {:play_files, files, opts}
# - Custom MediaHandler implementation with logging
# - Message flow: init -> session_start -> codec_negotiation -> stream_start
# - Handling :stop_playback and other control messages
#
# The MediaHandler pattern is MESSAGE-DRIVEN, not auto-play.
# Files are NEVER configured at initialization and NEVER played automatically.

require Logger

Logger.info("========================================")
Logger.info("MediaHandler Message Pattern Test Script")
Logger.info("========================================")

# ==============================================================================
# Custom MediaHandler with Verbose Logging
# ==============================================================================
#
# This handler implements the ParrotMedia.Handler behaviour and logs
# every callback invocation to demonstrate the media lifecycle.

defmodule VerboseMediaHandler do
  @moduledoc """
  A verbose MediaHandler that logs all callback invocations.

  Demonstrates the correct message-driven pattern:
  - init/1 - Initializes state WITHOUT any audio files
  - handle_session_start/3 - Called when session is created
  - handle_codec_negotiation/3 - Select codec from offered options
  - handle_negotiation_complete/4 - After SDP negotiation finishes
  - handle_stream_start/3 - Media stream about to start (NO auto-play!)
  - handle_info/2 - ONLY here do we respond to play messages
  """

  @behaviour ParrotMedia.Handler

  require Logger

  # ===========================================================================
  # Required Callbacks
  # ===========================================================================

  @impl true
  def init(args) do
    Logger.info("""
    [VerboseMediaHandler] INIT called
      Args: #{inspect(args)}

      NOTE: We do NOT configure any audio files here!
      Media is controlled ONLY via messages to handle_info/2
    """)

    # Initialize state - NO audio file configuration!
    {:ok,
     %{
       handler_name: Map.get(args, :handler_name, "VerboseHandler"),
       call_count: 0,
       playing: false,
       current_files: [],
       messages_received: []
     }}
  end

  @impl true
  def handle_session_start(session_id, opts, state) do
    Logger.info("""
    [VerboseMediaHandler] HANDLE_SESSION_START called
      Session ID: #{session_id}
      Opts: #{inspect(opts)}
      State: #{inspect(state)}
    """)

    {:ok, %{state | call_count: state.call_count + 1}}
  end

  @impl true
  def handle_codec_negotiation(offered_codecs, supported_codecs, state) do
    Logger.info("""
    [VerboseMediaHandler] HANDLE_CODEC_NEGOTIATION called
      Offered codecs: #{inspect(offered_codecs)}
      Supported codecs: #{inspect(supported_codecs)}
      State: #{inspect(state)}
    """)

    # Select first common codec
    selected =
      Enum.find(offered_codecs, fn c -> c in supported_codecs end) ||
        List.first(offered_codecs)

    Logger.info("  -> Selected codec: #{inspect(selected)}")
    {:ok, selected, %{state | call_count: state.call_count + 1}}
  end

  @impl true
  def handle_negotiation_complete(local_sdp, remote_sdp, selected_codec, state) do
    Logger.info("""
    [VerboseMediaHandler] HANDLE_NEGOTIATION_COMPLETE called
      Selected codec: #{inspect(selected_codec)}
      Local SDP length: #{String.length(local_sdp)} bytes
      Remote SDP length: #{String.length(remote_sdp)} bytes
      State: #{inspect(state)}
    """)

    {:ok, %{state | call_count: state.call_count + 1}}
  end

  @impl true
  def handle_stream_start(session_id, direction, state) do
    Logger.info("""
    [VerboseMediaHandler] HANDLE_STREAM_START called
      Session ID: #{session_id}
      Direction: #{inspect(direction)}
      State: #{inspect(state)}

      IMPORTANT: We return {:noreply, state} here!
      We do NOT automatically play any files.
      Files are ONLY played when we receive {:play_files, ...} messages.
    """)

    # Return :noreply - NO automatic playback!
    {:noreply, %{state | call_count: state.call_count + 1}}
  end

  # ===========================================================================
  # SDP Negotiation Callbacks (Optional)
  # ===========================================================================

  @impl true
  def handle_offer(sdp_offer, direction, state) do
    Logger.info("""
    [VerboseMediaHandler] HANDLE_OFFER called
      Direction: #{inspect(direction)}
      SDP Offer length: #{String.length(sdp_offer)} bytes
      State: #{inspect(state)}
    """)

    {:noreply, %{state | call_count: state.call_count + 1}}
  end

  # ===========================================================================
  # Message-Driven Media Control (handle_info/2)
  # ===========================================================================
  #
  # This is the KEY callback for media control!
  # All media operations are triggered by messages.

  @impl true
  def handle_info({:play_files, files, opts}, state) do
    loop = Keyword.get(opts, :loop, false)

    Logger.info("""
    [VerboseMediaHandler] HANDLE_INFO received {:play_files, files, opts}
      Files: #{inspect(files)}
      Options: #{inspect(opts)}
      Loop: #{loop}
      State: #{inspect(state)}

      Returning action: #{if loop, do: "{:play_loop, files}", else: "{:play_sequence, files}"}
    """)

    action = if loop, do: {:play_loop, files}, else: {:play_sequence, files}

    {[action],
     %{
       state
       | playing: true,
         current_files: files,
         messages_received: [{:play_files, files, opts} | state.messages_received]
     }}
  end

  @impl true
  def handle_info(:stop_playback, state) do
    Logger.info("""
    [VerboseMediaHandler] HANDLE_INFO received :stop_playback
      Current state: #{inspect(state)}

      Returning action: :stop
    """)

    {[:stop],
     %{
       state
       | playing: false,
         current_files: [],
         messages_received: [:stop_playback | state.messages_received]
     }}
  end

  @impl true
  def handle_info({:start_media}, state) do
    Logger.info("""
    [VerboseMediaHandler] HANDLE_INFO received {:start_media}
      State: #{inspect(state)}

      NOTE: This message signals media pipeline is ready.
      We still don't auto-play - wait for explicit {:play_files, ...}
    """)

    {:noreply, %{state | messages_received: [{:start_media} | state.messages_received]}}
  end

  @impl true
  def handle_info({:stop_media}, state) do
    Logger.info("""
    [VerboseMediaHandler] HANDLE_INFO received {:stop_media}
      State: #{inspect(state)}
    """)

    {:noreply,
     %{
       state
       | playing: false,
         messages_received: [{:stop_media} | state.messages_received]
     }}
  end

  # DTMF handling
  @impl true
  def handle_info({:dtmf, digit}, state) do
    Logger.info("""
    [VerboseMediaHandler] HANDLE_INFO received {:dtmf, digit}
      Digit: #{digit}
      State: #{inspect(state)}
    """)

    {:noreply, %{state | messages_received: [{:dtmf, digit} | state.messages_received]}}
  end

  # Catch-all for unknown messages
  @impl true
  def handle_info(msg, state) do
    Logger.info("""
    [VerboseMediaHandler] HANDLE_INFO received unknown message
      Message: #{inspect(msg)}
      State: #{inspect(state)}
    """)

    {:noreply, %{state | messages_received: [msg | state.messages_received]}}
  end
end

# ==============================================================================
# Demo: Direct Handler Testing (without full MediaSession)
# ==============================================================================
#
# This demonstrates the handler lifecycle by calling callbacks directly.

Logger.info("\n--- Demo 1: Direct Handler Callback Testing ---\n")

# Step 1: Initialize the handler
Logger.info("Step 1: Calling init/1")
{:ok, state} = VerboseMediaHandler.init(%{handler_name: "DirectTest"})

# Step 2: Session start
Logger.info("\nStep 2: Calling handle_session_start/3")
{:ok, state} = VerboseMediaHandler.handle_session_start("test_session_001", [], state)

# Step 3: Codec negotiation
Logger.info("\nStep 3: Calling handle_codec_negotiation/3")
{:ok, _codec, state} = VerboseMediaHandler.handle_codec_negotiation([:pcma, :pcmu], [:pcma], state)

# Step 4: SDP offer
Logger.info("\nStep 4: Calling handle_offer/3")
{:noreply, state} = VerboseMediaHandler.handle_offer("v=0\r\n...", :inbound, state)

# Step 5: Negotiation complete
Logger.info("\nStep 5: Calling handle_negotiation_complete/4")
{:ok, state} = VerboseMediaHandler.handle_negotiation_complete("local_sdp", "remote_sdp", :pcma, state)

# Step 6: Stream start - NOTE: returns {:noreply, state}, NO auto-play!
Logger.info("\nStep 6: Calling handle_stream_start/3")
{:noreply, state} = VerboseMediaHandler.handle_stream_start("test_session_001", :outbound, state)

# Step 7: Now send a message to play files
Logger.info("\nStep 7: Sending {:play_files, files, opts} message via handle_info/2")
{actions, state} = VerboseMediaHandler.handle_info({:play_files, ["welcome.wav", "menu.wav"], []}, state)
Logger.info("  Actions returned: #{inspect(actions)}")

# Step 8: Send stop_playback
Logger.info("\nStep 8: Sending :stop_playback message via handle_info/2")
{actions, state} = VerboseMediaHandler.handle_info(:stop_playback, state)
Logger.info("  Actions returned: #{inspect(actions)}")

# Step 9: Send play_files with loop option
Logger.info("\nStep 9: Sending {:play_files, files, loop: true} message")
{actions, state} = VerboseMediaHandler.handle_info({:play_files, ["hold_music.wav"], [loop: true]}, state)
Logger.info("  Actions returned: #{inspect(actions)}")

# Step 10: Show final state
Logger.info("\n--- Final Handler State ---")
Logger.info("  Handler name: #{state.handler_name}")
Logger.info("  Call count: #{state.call_count}")
Logger.info("  Currently playing: #{state.playing}")
Logger.info("  Current files: #{inspect(state.current_files)}")
Logger.info("  Messages received: #{inspect(Enum.reverse(state.messages_received))}")

# ==============================================================================
# Demo: Compare with DSL MediaHandler
# ==============================================================================

Logger.info("\n\n--- Demo 2: Comparing with Parrot.DSL.MediaHandler ---\n")

# The DSL MediaHandler follows the same pattern
Logger.info("Parrot.DSL.MediaHandler is the production handler used by Bridge.Handler")
Logger.info("It implements the same message-driven pattern:\n")

Logger.info("""
  1. init/1 - Initializes with call_id, NO audio files
  2. handle_session_start/3 - Logs session start
  3. handle_codec_negotiation/3 - Selects first offered codec
  4. handle_negotiation_complete/4 - Logs completion
  5. handle_stream_start/3 - Returns {:noreply, state} - NO AUTO-PLAY!
  6. handle_info({:play_files, files, opts}, state) - Returns {:play_sequence/loop, files}
  7. handle_info(:stop_playback, state) - Returns [:stop]
""")

# Demonstrate DSL MediaHandler
Logger.info("Testing Parrot.DSL.MediaHandler directly:\n")

{:ok, dsl_state} = Parrot.DSL.MediaHandler.init(%{call_id: "test_123"})
Logger.info("  init/1 returned: {:ok, #{inspect(dsl_state)}}")

{:ok, dsl_state} = Parrot.DSL.MediaHandler.handle_session_start("sess_001", [], dsl_state)
Logger.info("  handle_session_start/3 returned: {:ok, ...}")

{:noreply, dsl_state} = Parrot.DSL.MediaHandler.handle_stream_start("sess_001", :outbound, dsl_state)
Logger.info("  handle_stream_start/3 returned: {:noreply, ...} - NO AUTO-PLAY!")

{actions, _dsl_state} = Parrot.DSL.MediaHandler.handle_info({:play_files, ["test.wav"], []}, dsl_state)
Logger.info("  handle_info({:play_files, ...}) returned actions: #{inspect(actions)}")

# ==============================================================================
# Summary
# ==============================================================================

Logger.info("""

================================================================================
SUMMARY: MediaHandler Message-Driven Pattern
================================================================================

KEY POINTS:

1. NEVER put audio files in init/1 state
   - init/1 initializes handler state WITHOUT media configuration

2. NEVER auto-play in handle_stream_start/3
   - Always return {:noreply, state}
   - This callback signals stream is ready, not that playback should start

3. ONLY play files via handle_info/2 messages
   - {:play_files, files, opts} - Play files (sequence or loop based on opts)
   - :stop_playback - Stop current playback

4. Return media actions from handle_info/2
   - {:play_sequence, files} - Play files once in order
   - {:play_loop, files} - Play files continuously
   - :stop - Stop playback
   - {:noreply, state} - No media action needed

5. Message flow:
   init/1 -> handle_session_start/3 -> handle_codec_negotiation/3 ->
   handle_negotiation_complete/4 -> handle_stream_start/3 ->
   [wait for {:play_files, ...} message] -> handle_info/2

ANTI-PATTERNS TO AVOID:
  x Passing audio_file or welcome_file in init args
  x Playing files automatically in handle_stream_start/3
  x Configuring media behavior through initialization
  x Using audio_file parameter in MediaSession.start_link

================================================================================
""")
