defmodule Parrot.Examples.MiniPBX.Voicemail do
  @moduledoc """
  Voicemail handler for Mini PBX.

  Provides voicemail functionality for internal extensions:
  - Recording messages after greeting
  - Storage with caller/timestamp metadata
  - Retrieval via *86 with PIN verification
  - MWI (Message Waiting Indicator) notifications

  ## Recording Flow

  When a call is forwarded to voicemail (from Extensions handler):

      1. Play extension greeting (or default)
      2. Play "leave message after beep"
      3. Record message (max 2 minutes)
      4. Store in Mnesia with metadata
      5. Send MWI notification
      6. Play confirmation and hangup

  ## Retrieval Flow

  When user dials *86:

      1. Answer call
      2. Extract extension from caller
      3. Prompt for PIN
      4. Verify PIN (default: extension number)
      5. Play messages with controls:
         - 7: Delete message
         - 9: Save and continue
         - *: Repeat message

  ## Example

      # Forward to voicemail (called by Extensions handler)
      call
      |> assign(:voicemail, true)
      |> assign(:extension, "1001")
      |> play(Voicemail.get_greeting("1001"))

      # Check voicemail (dial *86)
      INVITE sip:*86@pbx.local
      From: <sip:1001@pbx.local>
  """

  use Parrot.InviteHandler

  require Logger

  alias Parrot.Examples.MiniPBX.Storage

  @max_recording_duration 120_000  # 2 minutes
  @voicemail_dir "/var/spool/voicemail"
  @default_greeting "default-voicemail-greeting.wav"

  # ===========================================================================
  # InviteHandler Callbacks
  # ===========================================================================

  @doc """
  Handles voicemail access via *86.

  Extracts the caller's extension and prompts for PIN.
  """
  @impl true
  def handle_invite(call) do
    # Extract extension from caller (e.g., sip:1001@pbx.local -> 1001)
    extension = extract_extension(call.from)

    Logger.info("[Voicemail] Access from extension #{extension}")

    call
    |> assign(:extension, extension)
    |> assign(:retrieval_mode, true)
    |> answer()
    |> play("enter-pin.wav", [])
    |> collect_dtmf(max_digits: 4, timeout: 10_000)
  end

  @doc """
  Handles play completion for voicemail recording flow.

  - After greeting: play "leave message after beep"
  - After beep prompt: start recording
  """
  @impl true
  def handle_play_complete(filename, call) do
    cond do
      # After beep prompt, start recording
      String.contains?(filename, "leave-message") or String.contains?(filename, "beep") ->
        extension = call.assigns[:extension]
        recording_path = voicemail_path(extension)

        Logger.info("[Voicemail] Starting recording for #{extension}: #{recording_path}")

        call
        |> record(recording_path, max_duration: @max_recording_duration, beep: true)

      # After greeting, play the beep prompt
      call.assigns[:voicemail] == true and call.assigns[:beep_played] != true ->
        call
        |> assign(:beep_played, true)
        |> play("leave-message-after-beep.wav", [])

      # After confirmation message, let default handling take over
      String.contains?(filename, "saved") or String.contains?(filename, "message") ->
        {:noreply, call}

      # For voicemail playback mode
      call.assigns[:playing_voicemails] == true ->
        handle_next_message(call)

      true ->
        {:noreply, call}
    end
  end

  @doc """
  Handles DTMF input during voicemail retrieval.

  - PIN verification
  - Playback controls (7=delete, 9=save, *=repeat)
  """
  @impl true
  def handle_dtmf(digits, call) when is_binary(digits) do
    cond do
      # PIN verification
      call.assigns[:retrieval_mode] == true and call.assigns[:pin_verified] != true ->
        verify_and_play(digits, call)

      # Playback controls
      call.assigns[:playing_voicemails] == true ->
        handle_playback_control(digits, call)

      true ->
        {:noreply, call}
    end
  end

  def handle_dtmf(:timeout, call) do
    Logger.info("[Voicemail] DTMF timeout")
    call
    |> play("goodbye.wav", [])
    |> hangup()
  end

  @doc """
  Handles recording completion - stores voicemail and sends MWI.
  """
  @impl true
  def handle_record_complete(filename, duration, call) do
    extension = call.assigns[:extension]
    caller = call.assigns[:caller]

    Logger.info("[Voicemail] Recording complete: #{filename} (#{duration}ms) from #{caller}")

    # Store voicemail in Mnesia
    :ok = Storage.store_voicemail(extension, caller, filename)

    # Send MWI notification
    notify_mwi(extension)

    call
    |> play("message-saved.wav", [])
    |> hangup()
  end

  # ===========================================================================
  # Public API
  # ===========================================================================

  @doc """
  Gets the greeting file for an extension.

  Returns the custom greeting if one exists, otherwise the default.
  """
  @spec get_greeting(String.t()) :: String.t()
  def get_greeting(extension) do
    custom_greeting = Path.join([@voicemail_dir, extension, "greeting.wav"])

    if File.exists?(custom_greeting) do
      custom_greeting
    else
      @default_greeting
    end
  end

  @doc """
  Sends MWI (Message Waiting Indicator) notification for an extension.

  This notifies the phone that it has new voicemail.
  Currently a stub - full implementation requires NOTIFY/SUBSCRIBE support.
  """
  @spec notify_mwi(String.t()) :: :ok
  def notify_mwi(extension) do
    Logger.info("[Voicemail] MWI notification for #{extension} (stub)")
    # TODO: Send SIP NOTIFY with message-summary body
    # Event: message-summary
    # Messages-Waiting: yes
    # Voice-Message: 1/0 (new/old)
    :ok
  end

  # ===========================================================================
  # Private Helpers
  # ===========================================================================

  defp verify_and_play(pin, call) do
    extension = call.assigns[:extension]

    if verify_pin(extension, pin) do
      Logger.info("[Voicemail] PIN verified for #{extension}")

      call
      |> assign(:pin_verified, true)
      |> assign(:playing_voicemails, true)
      |> play_voicemails()
    else
      Logger.info("[Voicemail] Invalid PIN for #{extension}")

      call
      |> play("invalid-pin.wav", [])
      |> hangup()
    end
  end

  defp verify_pin(extension, pin) do
    # Default PIN is the extension number
    # In production, this would check against a stored PIN
    pin == extension
  end

  defp play_voicemails(call) do
    extension = call.assigns[:extension]

    case Storage.get_voicemails(extension) do
      {:ok, []} ->
        call
        |> play("no-messages.wav", [])
        |> hangup()

      {:ok, messages} ->
        call
        |> assign(:messages, messages)
        |> assign(:message_index, 0)
        |> play_current_message()
    end
  end

  defp play_current_message(call) do
    messages = call.assigns[:messages]
    index = call.assigns[:message_index]

    if index < length(messages) do
      message = Enum.at(messages, index)

      call
      |> assign(:current_message, message)
      |> play(message.file_path, [])
    else
      # No more messages
      call
      |> play("end-of-messages.wav", [])
      |> hangup()
    end
  end

  defp handle_next_message(call) do
    index = (call.assigns[:message_index] || 0) + 1

    call
    |> assign(:message_index, index)
    |> play_current_message()
  end

  defp handle_playback_control("7", call) do
    # Delete current message
    message = call.assigns[:current_message]
    extension = call.assigns[:extension]

    if message do
      :ok = Storage.delete_voicemail(extension, message.id)
      Logger.info("[Voicemail] Deleted message #{message.id}")
    end

    call
    |> play("message-deleted.wav", [])
  end

  defp handle_playback_control("9", call) do
    # Save and continue to next
    call
    |> play("message-saved.wav", [])
  end

  defp handle_playback_control("*", call) do
    # Repeat current message
    message = call.assigns[:current_message]

    if message do
      call |> play(message.file_path, [])
    else
      {:noreply, call}
    end
  end

  defp handle_playback_control(_digit, call) do
    {:noreply, call}
  end

  defp voicemail_path(extension) do
    timestamp = DateTime.utc_now() |> DateTime.to_unix()
    Path.join([@voicemail_dir, extension, "msg_#{timestamp}.wav"])
  end

  defp extract_extension(uri) when is_binary(uri) do
    uri
    |> String.replace(~r/^sip:/i, "")
    |> String.split("@")
    |> List.first()
  end

  defp extract_extension(_), do: nil
end
