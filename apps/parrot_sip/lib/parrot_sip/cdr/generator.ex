defmodule ParrotSip.CDR.Generator do
  @moduledoc """
  Generates CDR structs from dialog data and timing information.

  The Generator is the core module that transforms SIP dialog state into
  standardized Call Detail Records (CDRs) upon call termination.

  ## Role-Based Field Mapping

  The Generator maps caller/callee fields based on the role (UAC or UAS):

  - **UAC (outbound)**: We initiated the call
    - caller = local party (us)
    - callee = remote party
    - direction = :outbound

  - **UAS (inbound)**: We received the call
    - caller = remote party
    - callee = local party (us)
    - direction = :inbound

  ## Timing Calculations

  For answered calls:
  - ring_duration_ms = answered_at - invite_received_at
  - talk_duration_ms = ended_at - answered_at

  For unanswered calls:
  - ring_duration_ms = ended_at - invite_received_at
  - talk_duration_ms = 0

  ## Usage

      dialog = %ParrotSip.Dialog{...}
      timing = %{
        invite_received_at: ~U[2024-01-01 10:00:00Z],
        answered_at: ~U[2024-01-01 10:00:10Z],
        ended_at: ~U[2024-01-01 10:05:10Z]
      }
      termination_cause = %ParrotSip.CDR.TerminationCause{
        party: :caller,
        sip_code: 200,
        reason: "BYE",
        method: :bye
      }

      {:ok, cdr} = ParrotSip.CDR.Generator.generate(dialog, timing, termination_cause)
  """

  alias ParrotSip.CDR
  alias ParrotSip.CDR.{Disposition, TerminationCause}
  alias ParrotSip.Dialog

  @doc """
  Generates a CDR from dialog data, timing information, and termination cause.

  ## Parameters

  - `dialog` - The SIP dialog struct containing call identifiers and URIs
  - `timing` - Map with :invite_received_at, :answered_at (or nil), and :ended_at
  - `termination_cause` - The termination cause struct

  ## Returns

  - `{:ok, cdr}` - Successfully generated CDR
  - `{:error, reason}` - Validation or generation error

  ## Examples

      iex> dialog = %Dialog{call_id: "abc@example.com", ...}
      iex> timing = %{invite_received_at: ~U[...], answered_at: ~U[...], ended_at: ~U[...]}
      iex> cause = %TerminationCause{party: :caller, sip_code: 200, ...}
      iex> {:ok, cdr} = Generator.generate(dialog, timing, cause)
  """
  @spec generate(Dialog.t(), map(), TerminationCause.t()) ::
          {:ok, CDR.t()} | {:error, term()}
  def generate(dialog, timing, termination_cause) do
    generate(dialog, timing, termination_cause, [])
  end

  @doc """
  Generates a CDR with additional options.

  ## Options

  - `:role` - Override role inference (:uac or :uas)
  - `:correlation_id` - Custom correlation ID (defaults to new UUID)
  - `:custom_fields` - Map of custom fields to include in CDR
  - `:media_info` - MediaInfo struct with media session data
  - `:caller_display_name` - Display name for the caller
  - `:callee_display_name` - Display name for the callee
  """
  @spec generate(Dialog.t(), map(), TerminationCause.t(), keyword()) ::
          {:ok, CDR.t()} | {:error, term()}
  def generate(nil, _timing, _termination_cause, _opts) do
    {:error, :invalid_dialog}
  end

  def generate(_dialog, _timing, nil, _opts) do
    {:error, :invalid_termination_cause}
  end

  def generate(%Dialog{call_id: nil}, _timing, _termination_cause, _opts) do
    {:error, :missing_call_id}
  end

  def generate(dialog, timing, termination_cause, opts) do
    with {:ok, validated_timing} <- validate_timing(timing),
         {:ok, role} <- determine_role(dialog, opts),
         {:ok, cdr} <- build_cdr(dialog, validated_timing, termination_cause, role, opts) do
      {:ok, cdr}
    end
  end

  # Validate that required timing fields are present
  defp validate_timing(%{invite_received_at: nil}), do: {:error, :missing_invite_received_at}
  defp validate_timing(%{ended_at: nil}), do: {:error, :missing_ended_at}

  defp validate_timing(%{invite_received_at: invite, ended_at: ended} = timing)
       when not is_nil(invite) and not is_nil(ended) do
    {:ok, timing}
  end

  defp validate_timing(_timing) do
    {:error, :invalid_timing_data}
  end

  # Determine role from options or infer from dialog ID
  defp determine_role(dialog, opts) do
    case Keyword.get(opts, :role) do
      nil -> infer_role_from_dialog(dialog)
      role when role in [:uac, :uas] -> {:ok, role}
      _invalid -> {:error, :invalid_role}
    end
  end

  # Infer role from dialog ID suffix (e.g., "...;uas" or "...;uac")
  defp infer_role_from_dialog(%Dialog{id: id}) when is_binary(id) do
    cond do
      String.ends_with?(id, ";uas") -> {:ok, :uas}
      String.ends_with?(id, ";uac") -> {:ok, :uac}
      # Default to UAS if cannot determine (most common server use case)
      true -> {:ok, :uas}
    end
  end

  defp infer_role_from_dialog(_dialog), do: {:ok, :uas}

  # Build the complete CDR struct
  defp build_cdr(dialog, timing, termination_cause, role, opts) do
    {caller_uri, caller_tag, callee_uri, callee_tag, direction} =
      map_role_fields(dialog, role)

    ring_duration_ms = calculate_ring_duration(timing)
    talk_duration_ms = calculate_talk_duration(timing)
    was_answered = not is_nil(timing[:answered_at])
    disposition = Disposition.from_sip_code(termination_cause.sip_code, was_answered)

    cdr = %CDR{
      id: UUID.uuid4(),
      correlation_id: Keyword.get(opts, :correlation_id, UUID.uuid4()),
      call_id: dialog.call_id,
      dialog_id: dialog.id,
      caller_uri: caller_uri,
      caller_tag: caller_tag,
      caller_display_name: Keyword.get(opts, :caller_display_name),
      callee_uri: callee_uri,
      callee_tag: callee_tag,
      callee_display_name: Keyword.get(opts, :callee_display_name),
      disposition: disposition,
      termination_cause: termination_cause,
      invite_received_at: timing.invite_received_at,
      answered_at: timing[:answered_at],
      ended_at: timing.ended_at,
      ring_duration_ms: ring_duration_ms,
      talk_duration_ms: talk_duration_ms,
      direction: direction,
      transport: dialog.transport,
      media_info: Keyword.get(opts, :media_info),
      custom_fields: Keyword.get(opts, :custom_fields, %{})
    }

    {:ok, cdr}
  end

  # Map fields based on role perspective
  # UAC (outbound): caller=local, callee=remote
  # UAS (inbound): caller=remote, callee=local
  defp map_role_fields(dialog, :uac) do
    {
      dialog.local_uri,
      dialog.local_tag,
      dialog.remote_uri,
      dialog.remote_tag,
      :outbound
    }
  end

  defp map_role_fields(dialog, :uas) do
    {
      dialog.remote_uri,
      dialog.remote_tag,
      dialog.local_uri,
      dialog.local_tag,
      :inbound
    }
  end

  # Calculate ring duration in milliseconds
  # For answered calls: answered_at - invite_received_at
  # For unanswered calls: ended_at - invite_received_at
  defp calculate_ring_duration(%{answered_at: answered, invite_received_at: invite})
       when not is_nil(answered) do
    DateTime.diff(answered, invite, :millisecond)
  end

  defp calculate_ring_duration(%{ended_at: ended, invite_received_at: invite}) do
    DateTime.diff(ended, invite, :millisecond)
  end

  # Calculate talk duration in milliseconds
  # For answered calls: ended_at - answered_at
  # For unanswered calls: 0
  defp calculate_talk_duration(%{answered_at: nil}), do: 0

  defp calculate_talk_duration(%{answered_at: answered, ended_at: ended}) do
    DateTime.diff(ended, answered, :millisecond)
  end
end
