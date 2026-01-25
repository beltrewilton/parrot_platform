defmodule ParrotSip.DialogStatem do
  @moduledoc """
  SIP Dialog State Machine Implementation

  Implements RFC 3261 Section 12 - Dialogs using Erlang's `:gen_statem` behavior.
  This module provides stateful management of SIP dialogs, tracking dialog lifecycle
  from creation through termination. For pure functional dialog operations, see
  `ParrotSip.Dialog`.

  ## RFC 3261 Section 12 - Dialogs

  A dialog represents a peer-to-peer SIP relationship between two user agents that
  persists for some time. Dialogs facilitate proper sequencing of messages and
  provide context for SIP transactions.

  Dialog states per RFC 3261:
  - **Early**: Created by provisional (1xx) responses, waiting for final response
  - **Confirmed**: Established by 2xx responses, dialog is fully established
  - **Terminated**: Dialog has ended (BYE, timeout, or error)

  ## State Machine Diagram

  ```
                                INVITE Request/Response
                                        |
                                        v
                              +------------------+
                              |      :early      |<----+ 1xx response
                              +------------------+     |
                                |              |       |
                        2xx     |              +-------+
                      response  |
                                |
                                v
                              +------------------+
                              |   :confirmed     |
                              +------------------+
                                |
                        BYE     |
                      or error  |
                                v
                              +------------------+
                              |  :terminated     |
                              +------------------+
                                        |
                                        v
                                    (stopped)
  ```

  ## Dialog Types

  - **INVITE dialogs**: Created by INVITE/2xx, used for sessions (e.g., voice calls)
  - **SUBSCRIBE dialogs**: Created by SUBSCRIBE/2xx, used for event subscriptions

  ## Events Handled

  - `{:call, from, {:uas_request, sip_msg}}` - Process UAS (server) request
  - `{:cast, {:uas_response, resp, req}}` - Process UAS response
  - `{:call, from, {:uac_request, sip_msg}}` - Create UAC (client) request
  - `{:cast, {:uac_trans_result, result}}` - Process UAC transaction result
  - `{:cast, {:set_owner, pid}}` - Set and monitor dialog owner process
  - `{:state_timeout, :subscription_expired}` - Handle subscription expiration
  - `{:info, {:DOWN, ...}}` - Handle owner process termination

  ## Implementation Notes

  - Uses `:state_functions` callback mode for clear state separation
  - Each dialog is a separate `:gen_statem` process
  - Registered in `ParrotSip.Registry` by dialog ID
  - Managed by `ParrotSip.Dialog.Supervisor` with `:temporary` restart strategy
  - Delegates pure functional operations to `ParrotSip.Dialog` module
  - Monitors owner process and terminates when owner dies

  ## References

  - RFC 3261 Section 12: Dialogs
  - RFC 3261 Section 12.1: Creation of a Dialog
  - RFC 3261 Section 12.2: Requests within a Dialog
  - RFC 3261 Section 12.3: Termination of a Dialog
  - RFC 3265: SIP-Specific Event Notification (for SUBSCRIBE dialogs)
  """
  @behaviour :gen_statem

  require Logger

  alias ParrotSip.{Dialog, Message, Branch, DialogBroadcast}
  alias ParrotSip.CDR
  alias ParrotSip.CDR.{Generator, Dispatcher, TerminationCause}
  alias ParrotSip.Headers.{Contact, Via}

  @type trans :: {:trans, pid()}
  @type trans_result :: {:message, any()} | {:stop, any()}
  @type dialog_handle :: pid()
  @type dialog_type :: :invite | :notify
  @type start_link_ret :: {:ok, pid()} | {:error, {:already_started, pid()}} | {:error, term()}

  defmodule Data do
    @moduledoc false
    defstruct [
      # Dialog ID
      :id,
      # Dialog state
      :dialog,
      # Local contact
      :local_contact,
      # Early branch for forked responses
      :early_branch,
      # Log ID for logging
      :log_id,
      # Dialog type (:invite or :notify)
      :dialog_type,
      need_cleanup: true,
      # Owner process monitor
      owner_mon: nil,
      # Flag indicating if this dialog was recovered from stored state
      recovered: false,
      # CDR timing fields
      # Timestamp when INVITE was received (dialog creation)
      invite_received_at: nil,
      # Timestamp when call was answered (:early -> :confirmed transition)
      answered_at: nil
    ]

    @type t :: %__MODULE__{
            id: String.t() | nil,
            dialog: Dialog.t() | nil,
            local_contact: Contact.t() | nil,
            early_branch: String.t() | nil,
            log_id: String.t() | nil,
            dialog_type: :invite | :notify | nil,
            need_cleanup: boolean(),
            owner_mon: reference() | nil,
            recovered: boolean(),
            invite_received_at: DateTime.t() | nil,
            answered_at: DateTime.t() | nil
          }
  end

  # API

  def child_spec(args) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [args]},
      type: :worker,
      restart: :temporary,
      shutdown: 5000
    }
  end

  @spec start_link(term()) :: start_link_ret()
  def start_link(args) do
    :gen_statem.start_link(
      {:via, Registry, {ParrotSip.Registry, dialog_registry_key(args)}},
      __MODULE__,
      args,
      []
    )
  end

  @doc """
  Start a DialogStatem from recovered state (cluster failover).
  Skips initial negotiation, starts directly in :confirmed state.

  ## Parameters
    - `stored_state` - Map containing dialog state fields from DialogBroadcast

  ## Returns
    - `{:ok, pid}` on success
    - `{:error, reason}` on failure

  ## Example

      stored_state = %{
        call_id: "call-123@example.com",
        local_tag: "local-tag",
        remote_tag: "remote-tag",
        local_uri: "sip:alice@example.com",
        remote_uri: "sip:bob@example.com",
        local_seq: 1,
        remote_seq: 1,
        secure: false,
        route_set: []
      }

      {:ok, pid} = DialogStatem.start_recovered(stored_state)
  """
  @spec start_recovered(map()) :: :gen_statem.start_ret()
  def start_recovered(stored_state) do
    :gen_statem.start_link(__MODULE__, {:recover, stored_state}, [])
  end

  @impl :gen_statem
  def callback_mode, do: :state_functions

  @impl :gen_statem
  def init({:uas, resp_sip_msg, req_sip_msg}) do
    Logger.debug(
      "dialog: init called with UAS args: #{inspect(resp_sip_msg)}, #{inspect(req_sip_msg)}"
    )

    # Create dialog from UAS perspective
    {:ok, dialog} = Dialog.uas_create(req_sip_msg, resp_sip_msg)
    dialog_id = dialog.id

    Logger.info("dialog: initializing with ID #{inspect(dialog_id)}")

    case Registry.register(ParrotSip.Registry, dialog_id, nil) do
      {:ok, _} ->
        Logger.info("dialog: successfully registered with ID #{inspect(dialog_id)}")

      {:error, {:already_registered, _}} ->
        Logger.warning("dialog: already registered with ID #{inspect(dialog_id)}")
    end

    data = %Data{
      id: dialog_id,
      dialog: dialog,
      local_contact: Message.get_header(req_sip_msg, "contact"),
      log_id: uas_log_id(resp_sip_msg),
      dialog_type: dialog_type(req_sip_msg),
      invite_received_at: DateTime.utc_now()
    }

    # Set a timer for NOTIFY dialogs
    actions =
      if data.dialog_type == :notify do
        # Get expiration from Expires header or default to 3600 seconds
        expires = get_expires(req_sip_msg, 3600)

        Logger.info(
          "dialog #{inspect(data.id)}: setting subscription timeout for #{expires} seconds"
        )

        [{:state_timeout, expires * 1000, :subscription_expired}]
      else
        []
      end

    initial_state = dialog.state
    Logger.info("dialog #{inspect(data.id)}: starting in #{inspect(initial_state)} state")

    req_method = req_sip_msg.method
    res_method = resp_sip_msg.method
    call_id = req_sip_msg.call_id

    Logger.metadata(
      dialog_id: data.id,
      dialog_type: data.dialog_type,
      req_method: req_method,
      res_method: res_method,
      call_id: call_id
    )

    # Broadcast creation and set answered_at if starting directly in confirmed state
    data =
      if initial_state == :confirmed do
        broadcast_state = %{
          call_id: dialog.call_id,
          local_tag: dialog.local_tag,
          remote_tag: dialog.remote_tag,
          state: :confirmed,
          owner_node: node()
        }

        maybe_broadcast_create(dialog.id, broadcast_state)
        # Set answered_at for dialogs starting directly in confirmed state
        %{data | answered_at: DateTime.utc_now()}
      else
        data
      end

    {:ok, initial_state, data, actions}
  end

  def init({:uac, out_req, %Message{status_code: code} = resp_sip_msg})
      when code >= 100 and code < 200 do
    {:ok, dialog} = Dialog.uac_create(out_req, resp_sip_msg)

    branch = get_branch_from_request(out_req)
    branch_key = "branch:" <> branch
    Logger.debug("dialog: early branch #{inspect(branch_key)}")
    Registry.register(ParrotSip.Registry, branch_key, nil)

    # Register with dialog ID (may already be registered via start_link)
    case Registry.register(ParrotSip.Registry, dialog.id, nil) do
      {:ok, _} ->
        Logger.debug("dialog: registered with ID #{inspect(dialog.id)}")

      {:error, {:already_registered, _}} ->
        Logger.debug("dialog: already registered with ID #{inspect(dialog.id)}")
    end

    data = %Data{
      id: dialog.id,
      dialog: dialog,
      local_contact: Message.get_header(out_req, "contact"),
      early_branch: branch,
      log_id: uac_log_id(resp_sip_msg),
      dialog_type: dialog_type(out_req),
      invite_received_at: DateTime.utc_now()
    }

    initial_state = dialog.state
    Logger.info("dialog #{inspect(dialog.id)}: starting in #{inspect(initial_state)} state")
    {:ok, initial_state, data}
  end

  def init({:uac, out_req, resp_sip_msg}) do
    {:ok, dialog} = Dialog.uac_create(out_req, resp_sip_msg)

    # Register with dialog ID (may already be registered via start_link)
    case Registry.register(ParrotSip.Registry, dialog.id, nil) do
      {:ok, _} ->
        Logger.debug("dialog: registered with ID #{inspect(dialog.id)}")

      {:error, {:already_registered, _}} ->
        Logger.debug("dialog: already registered with ID #{inspect(dialog.id)}")
    end

    data = %Data{
      id: dialog.id,
      dialog: dialog,
      local_contact: Message.get_header(out_req, "contact"),
      early_branch: nil,
      log_id: uac_log_id(resp_sip_msg),
      dialog_type: dialog_type(out_req),
      invite_received_at: DateTime.utc_now()
    }

    initial_state = dialog.state
    Logger.info("dialog #{inspect(dialog.id)}: starting in #{inspect(initial_state)} state")

    # Broadcast creation and set answered_at if starting directly in confirmed state
    data =
      if initial_state == :confirmed do
        broadcast_state = %{
          call_id: dialog.call_id,
          local_tag: dialog.local_tag,
          remote_tag: dialog.remote_tag,
          state: :confirmed,
          owner_node: node()
        }

        maybe_broadcast_create(dialog.id, broadcast_state)
        # Set answered_at for dialogs starting directly in confirmed state
        %{data | answered_at: DateTime.utc_now()}
      else
        data
      end

    {:ok, initial_state, data}
  end

  @doc false
  def init({:recover, stored_state}) do
    Logger.info("[DialogStatem] Recovering dialog #{stored_state.call_id}")

    # RFC 3261 Section 12: Generate dialog ID from call-id, local-tag, remote-tag
    # For recovered dialogs, we assume UAS perspective (local=to_tag, remote=from_tag)
    dialog_id = Dialog.generate_id(:uas, stored_state.call_id, stored_state.local_tag, stored_state.remote_tag)

    # Build Dialog struct from stored state
    dialog = %Dialog{
      id: dialog_id,
      state: :confirmed,
      call_id: stored_state.call_id,
      local_tag: stored_state.local_tag,
      remote_tag: stored_state.remote_tag,
      local_uri: stored_state.local_uri,
      remote_uri: stored_state.remote_uri,
      remote_target: Map.get(stored_state, :remote_target),
      local_seq: stored_state.local_seq,
      remote_seq: stored_state.remote_seq,
      route_set: Map.get(stored_state, :route_set, []),
      secure: Map.get(stored_state, :secure, false),
      local_host: Map.get(stored_state, :local_host),
      local_port: Map.get(stored_state, :local_port),
      transport: Map.get(stored_state, :transport)
    }

    # Register the dialog
    case Registry.register(ParrotSip.Registry, dialog_id, nil) do
      {:ok, _} ->
        Logger.info("[DialogStatem] Recovered dialog registered with ID #{inspect(dialog_id)}")

      {:error, {:already_registered, _}} ->
        Logger.warning("[DialogStatem] Recovered dialog already registered: #{inspect(dialog_id)}")
    end

    # For recovered dialogs, use stored timing or fall back to current time
    now = DateTime.utc_now()

    data = %Data{
      id: dialog_id,
      dialog: dialog,
      local_contact: nil,
      early_branch: nil,
      log_id: "recovered-#{stored_state.call_id}",
      dialog_type: :invite,
      recovered: true,
      invite_received_at: Map.get(stored_state, :invite_received_at, now),
      answered_at: Map.get(stored_state, :answered_at, now)
    }

    Logger.info("[DialogStatem] Dialog #{inspect(dialog_id)} recovered successfully in :confirmed state")

    {:ok, :confirmed, data}
  end

  # Update to replace "Dialog.is_complete" by pattern matching on the Message struct below
  # {
  #   from: %From{parameters: %{"tag" => from_tag}},
  #   to: %To{parameters: %{"tag" => to_tag}}
  # }
  #
  # There are quite a few places to clean up like this (might be able to get rid of a lot of Dialog or all of it)

  @spec uas_find(Message.t()) :: {:ok, dialog_handle()} | :not_found
  def uas_find(%Message{
        from: %{parameters: %{"tag" => from_tag}},
        to: %{parameters: %{"tag" => to_tag}},
        call_id: call_id
      }) do
    # For UAS (incoming request): local=to_tag (us), remote=from_tag (them)
    dialog_id_str = Dialog.generate_id(:uas, call_id, to_tag, from_tag)
    Logger.info("uas_find: looking for dialog with ID #{inspect(dialog_id_str)}")

    case Registry.lookup(ParrotSip.Registry, dialog_id_str) do
      [{pid, _}] ->
        Logger.info("uas_find: found dialog #{inspect(dialog_id_str)} at PID #{inspect(pid)}")
        {:ok, pid}

      [] ->
        Logger.warning("uas_find: dialog #{inspect(dialog_id_str)} not found in registry")
        :not_found
    end
  end

  def uas_find(%Message{}) do
    Logger.debug("uas_find: incomplete dialog ID, not searching")
    :not_found
  end

  @spec uas_request(Message.t()) :: :process | {:reply, Message.t()}
  def uas_request(
        %Message{
          from: %{parameters: %{"tag" => from_tag}},
          to: %{parameters: %{"tag" => to_tag}},
          call_id: call_id
        } = sip_msg
      ) do
    Logger.debug("dialog: uas_request #{inspect(sip_msg)}")

    # For UAS: local=to_tag, remote=from_tag
    dialog_id_str = Dialog.generate_id(:uas, call_id, to_tag, from_tag)
    Logger.debug("dialog: constructed dialog id #{inspect(dialog_id_str)} from request")

    case Registry.lookup(ParrotSip.Registry, dialog_id_str) do
      [] ->
        Logger.debug(
          "dialog #{uas_log_id(sip_msg)}: dialog not found (dialog tracking not yet implemented)"
        )

        resp = Message.reply(sip_msg, 481, "Call/Transaction Does Not Exist")
        {:reply, resp}

      [{dialog_pid, _}] ->
        Logger.debug("dialog #{inspect(dialog_pid)}: found dialog")

        try do
          :gen_statem.call(dialog_pid, {:uas_request, sip_msg}, 5000)
        catch
          :exit, {reason, _} when reason in [:normal, :noproc, :timeout] ->
            resp = Message.reply(sip_msg, 481, "Call/Transaction Does Not Exist")
            {:reply, resp}
        end
    end
  end

  def uas_request(%Message{} = sip_msg) do
    Logger.debug("dialog: no complete dialog id in request")
    uas_validate_request(sip_msg)
  end

  @spec uas_response(Message.t(), Message.t()) :: Message.t()
  def uas_response(
        %Message{
          from: %{parameters: %{"tag" => from_tag}},
          to: %{parameters: %{"tag" => to_tag}},
          call_id: call_id
        } = resp_sip_msg,
        %Message{} = req_sip_msg
      ) do
    Logger.debug("dialog: uas_response #{inspect(resp_sip_msg)}")

    # For UAS: local=to_tag, remote=from_tag
    dialog_id_str = Dialog.generate_id(:uas, call_id, to_tag, from_tag)
    Logger.debug("dialog: constructed dialog id #{inspect(dialog_id_str)} from response")

    case Registry.lookup(ParrotSip.Registry, dialog_id_str) do
      [] ->
        Logger.debug(
          "dialog #{uas_log_id(resp_sip_msg)}: dialog not found (dialog tracking not yet implemented)"
        )

        uas_maybe_create_dialog(resp_sip_msg, req_sip_msg)

      [{dialog_pid, _}] ->
        Logger.debug("dialog #{inspect(dialog_pid)}: found dialog")
        uas_pass_response(dialog_pid, resp_sip_msg, req_sip_msg)
    end
  end

  def uas_response(%Message{} = resp_sip_msg, %Message{}) do
    Logger.debug("dialog: no complete dialog id in response")
    resp_sip_msg
  end

  @spec uac_request(String.t(), Message.t()) ::
          {:ok, Message.t()} | {:error, :no_dialog} | {:error, :timeout}
  def uac_request(dialog_id, sip_msg) do
    case Registry.lookup(ParrotSip.Registry, dialog_id) do
      [{dialog_pid, _}] ->
        try do
          :gen_statem.call(dialog_pid, {:uac_request, sip_msg}, 5000)
        catch
          :exit, {:timeout, _} -> {:error, :timeout}
        end

      [] ->
        {:error, :no_dialog}
    end
  end

  @spec uac_result(Message.t(), trans_result()) :: :ok
  def uac_result(
        %Message{
          from: %{parameters: %{"tag" => from_tag}},
          to: %{parameters: %{"tag" => to_tag}},
          call_id: call_id
        } = out_req,
        trans_result
      ) do
    # For UAC: local=from_tag (us), remote=to_tag (them)
    dialog_id_str = Dialog.generate_id(:uac, call_id, from_tag, to_tag)

    Registry.lookup(ParrotSip.Registry, dialog_id_str)
    |> handle_registry_lookup_result()
    |> handle_complete_dialog_lookup(out_req, trans_result)
  end

  def uac_result(%Message{} = out_req, trans_result) do
    handle_incomplete_dialog(out_req, trans_result)
  end

  # Convert Registry.lookup result to standard format
  defp handle_registry_lookup_result([{pid, _}]), do: {:ok, pid}
  defp handle_registry_lookup_result([]), do: {:error, :no_dialog}

  # Dialog found - forward the transaction result
  defp handle_complete_dialog_lookup({:ok, dialog_pid}, _out_req, trans_result) do
    uac_trans_result(dialog_pid, trans_result)
  end

  # Dialog not found - log warning
  defp handle_complete_dialog_lookup({:error, :no_dialog}, out_req, _trans_result) do
    Logger.warning("dialog: #{uac_log_id(out_req)} is not found for request #{out_req.method}")
    :ok
  end

  # Handle incomplete dialog with message response
  defp handle_incomplete_dialog(out_req, {:message, response}) do
    handle_message_result(out_req, response)
  end

  # Handle incomplete dialog with stop signal
  defp handle_incomplete_dialog(out_req, {:stop, reason}) do
    handle_stop_result(out_req, reason)
  end

  # Response has complete dialog info (both tags present)
  defp handle_message_result(
         %Message{
           from: %{parameters: %{"tag" => from_tag}},
           call_id: call_id
         } = out_req,
         %Message{to: %{parameters: %{"tag" => to_tag}}} = response
       ) do
    # For UAC: local=from_tag, remote=to_tag
    dialog_id_str = Dialog.generate_id(:uac, call_id, from_tag, to_tag)

    Registry.lookup(ParrotSip.Registry, dialog_id_str)
    |> handle_registry_lookup_result()
    |> handle_dialog_lookup_for_response(out_req, response, dialog_id_str)
  end

  # Response missing to-tag - cannot create dialog
  defp handle_message_result(_out_req, _response) do
    Logger.debug("dialog: response has no to-tag, not creating dialog")
    :ok
  end

  # Dialog found - update it
  defp handle_dialog_lookup_for_response({:ok, dialog_pid}, _out_req, response, dialog_id_str) do
    Logger.debug("dialog: found dialog by ID #{dialog_id_str}, updating")
    uac_trans_result(dialog_pid, {:message, response})
  end

  # Dialog not found - create new one
  defp handle_dialog_lookup_for_response({:error, :no_dialog}, out_req, response, _dialog_id_str) do
    Logger.debug("dialog: no dialog found for to-tag, creating new")
    uac_no_dialog_result(out_req, {:message, response})
  end

  # Handle stop result for incomplete dialog
  defp handle_stop_result(out_req, reason) do
    out_req
    |> get_branch_from_request()
    |> lookup_early_dialog()
    |> handle_early_dialog_lookup(reason)
  end

  # Look up early dialog by branch
  defp lookup_early_dialog(branch) do
    branch_key = "branch:" <> branch
    Registry.lookup(ParrotSip.Registry, branch_key)
  end

  # Early dialog found - terminate it
  defp handle_early_dialog_lookup([{dialog_pid, _}], reason) do
    Logger.debug("dialog: transaction stopped (#{inspect(reason)}), terminating early dialog")
    uac_trans_result(dialog_pid, {:stop, reason})
  end

  # No early dialog - nothing to clean up
  defp handle_early_dialog_lookup([], _reason) do
    :ok
  end

  @spec set_owner(pid(), String.t()) :: :ok
  def set_owner(pid, dialog_id) when is_pid(pid) do
    case Registry.lookup(ParrotSip.Registry, dialog_id) do
      [{dialog_pid, _}] ->
        :gen_statem.cast(dialog_pid, {:set_owner, pid})

      [] ->
        :ok
    end
  end

  @spec count() :: non_neg_integer()
  def count do
    ParrotSip.Dialog.Supervisor.num_active()
  end

  # ===========================================================================
  # Public Introspection APIs
  # ===========================================================================

  @doc """
  Returns the current state name of the dialog state machine.

  ## Returns
    - `:early` - Dialog in early state (provisional responses received)
    - `:confirmed` - Dialog is confirmed (2xx received)
    - `:terminated` - Dialog is terminated

  ## Example

      {:ok, pid} = DialogStatem.start_link({:uas, response, invite})
      DialogStatem.get_state(pid)
      # => :confirmed
  """
  @spec get_state(pid()) :: :early | :confirmed | :terminated
  def get_state(pid) when is_pid(pid) do
    :gen_statem.call(pid, :get_state)
  end

  @doc """
  Returns the dialog ID (the ID used for Registry lookup).

  ## Returns
    - `{:ok, dialog_id}` where dialog_id is a string

  ## Example

      {:ok, pid} = DialogStatem.start_link({:uas, response, invite})
      DialogStatem.get_dialog_id(pid)
      # => {:ok, "uas:call-id:local-tag:remote-tag"}
  """
  @spec get_dialog_id(pid()) :: {:ok, String.t() | nil}
  def get_dialog_id(pid) when is_pid(pid) do
    :gen_statem.call(pid, :get_dialog_id)
  end

  @doc """
  Returns the early branch for UAC dialogs with provisional responses.

  ## Returns
    - `{:ok, branch}` where branch is a string, or nil if not set

  ## Example

      {:ok, pid} = DialogStatem.start_link({:uac, invite, provisional_response})
      DialogStatem.get_early_branch(pid)
      # => {:ok, "z9hG4bK-abc123"}
  """
  @spec get_early_branch(pid()) :: {:ok, String.t() | nil}
  def get_early_branch(pid) when is_pid(pid) do
    :gen_statem.call(pid, :get_early_branch)
  end

  @doc """
  Returns the dialog type (:invite or :notify).

  ## Returns
    - `{:ok, :invite}` for INVITE dialogs
    - `{:ok, :notify}` for SUBSCRIBE/NOTIFY dialogs

  ## Example

      {:ok, pid} = DialogStatem.start_link({:uas, response, subscribe_msg})
      DialogStatem.get_dialog_type(pid)
      # => {:ok, :notify}
  """
  @spec get_dialog_type(pid()) :: {:ok, :invite | :notify | nil}
  def get_dialog_type(pid) when is_pid(pid) do
    :gen_statem.call(pid, :get_dialog_type)
  end

  @doc """
  Returns a summary of the dialog information.

  ## Returns
    - `{:ok, %{id: ..., call_id: ..., state: ..., local_tag: ..., remote_tag: ...}}`

  ## Example

      {:ok, pid} = DialogStatem.start_link({:uas, response, invite})
      DialogStatem.get_dialog_info(pid)
      # => {:ok, %{id: "...", call_id: "...", state: :confirmed, local_tag: "...", remote_tag: "..."}}
  """
  @spec get_dialog_info(pid()) :: {:ok, map()}
  def get_dialog_info(pid) when is_pid(pid) do
    :gen_statem.call(pid, :get_dialog_info)
  end

  @doc """
  Returns whether this dialog was recovered from cluster failover.

  ## Returns
    - `{:ok, true}` if the dialog was recovered
    - `{:ok, false}` if the dialog was created normally

  ## Example

      {:ok, pid} = DialogStatem.start_recovered(stored_state)
      DialogStatem.is_recovered?(pid)
      # => {:ok, true}
  """
  @spec is_recovered?(pid()) :: {:ok, boolean()}
  def is_recovered?(pid) when is_pid(pid) do
    :gen_statem.call(pid, :is_recovered?)
  end

  @doc """
  Returns timing data for CDR generation.

  ## Returns
    - `{:ok, %{invite_received_at: DateTime.t() | nil, answered_at: DateTime.t() | nil}}`

  ## Example

      {:ok, pid} = DialogStatem.start_link({:uas, response, invite})
      DialogStatem.get_timing_data(pid)
      # => {:ok, %{invite_received_at: ~U[2026-01-10 10:00:00Z], answered_at: ~U[2026-01-10 10:00:05Z]}}
  """
  @spec get_timing_data(pid()) :: {:ok, %{invite_received_at: DateTime.t() | nil, answered_at: DateTime.t() | nil}}
  def get_timing_data(pid) when is_pid(pid) do
    :gen_statem.call(pid, :get_timing_data)
  end

  @doc """
  Returns the full dialog data for recovery purposes.

  This returns all dialog fields needed for cluster failover recovery,
  including URIs, sequence numbers, routing, and transport info.

  ## Returns
    - `{:ok, dialog}` - The full dialog struct

  ## Example

      {:ok, pid} = DialogStatem.start_link({:uas, response, invite})
      {:ok, dialog} = DialogStatem.get_dialog_data(pid)
      # dialog contains all fields: call_id, local_uri, remote_uri, etc.
  """
  @spec get_dialog_data(pid()) :: {:ok, ParrotSip.Dialog.t()}
  def get_dialog_data(pid) when is_pid(pid) do
    :gen_statem.call(pid, :get_dialog_data)
  end

  # State Functions

  # Early state
  def early({:call, from}, :get_state, _data) do
    {:keep_state_and_data, [{:reply, from, :early}]}
  end

  def early({:call, from}, request, data) when request in [:get_dialog_id, :get_early_branch, :get_dialog_type, :get_dialog_info, :is_recovered?, :get_timing_data, :get_dialog_data] do
    result = handle_introspection_call(request, data)
    {:keep_state_and_data, [{:reply, from, result}]}
  end

  def early({:call, from}, {:uas_request, req_sip_msg}, data) do
    process_uas_request(:early, req_sip_msg, data, from)
  end

  def early(:cast, {:uas_response, resp_sip_msg, req_sip_msg}, data) do
    process_uas_response(:early, resp_sip_msg, req_sip_msg, data)
  end

  def early(:cast, {:uac_trans_result, trans_result}, data) do
    process_uac_trans_result(:early, trans_result, data)
  end

  def early({:call, from}, {:uac_request, req_sip_msg}, data) do
    process_uac_request(:early, req_sip_msg, data, from)
  end

  def early(:cast, {:set_owner, pid}, data) do
    process_set_owner(:early, pid, data)
  end

  def early(:info, {:DOWN, _ref, :process, _pid, _reason}, data) do
    Logger.info("dialog #{inspect(data.id)}: owner process terminated")
    {:stop, :normal}
  end

  def early(event_type, event_content, data) do
    handle_event(event_type, event_content, data)
  end

  # Confirmed state
  def confirmed({:call, from}, :get_state, _data) do
    {:keep_state_and_data, [{:reply, from, :confirmed}]}
  end

  def confirmed({:call, from}, request, data) when request in [:get_dialog_id, :get_early_branch, :get_dialog_type, :get_dialog_info, :is_recovered?, :get_timing_data, :get_dialog_data] do
    result = handle_introspection_call(request, data)
    {:keep_state_and_data, [{:reply, from, result}]}
  end

  def confirmed({:call, from}, {:uas_request, req_sip_msg}, data) do
    process_uas_request(:confirmed, req_sip_msg, data, from)
  end

  def confirmed(:cast, {:uas_response, resp_sip_msg, req_sip_msg}, data) do
    process_uas_response(:confirmed, resp_sip_msg, req_sip_msg, data)
  end

  def confirmed(:cast, {:uac_trans_result, trans_result}, data) do
    process_uac_trans_result(:confirmed, trans_result, data)
  end

  def confirmed({:call, from}, {:uac_request, req_sip_msg}, data) do
    process_uac_request(:confirmed, req_sip_msg, data, from)
  end

  def confirmed(:cast, {:set_owner, pid}, data) do
    process_set_owner(:confirmed, pid, data)
  end

  def confirmed(:state_timeout, :subscription_expired, data) do
    Logger.info("dialog #{inspect(data.id)}: subscription expired")
    {:stop, :normal}
  end

  def confirmed(:info, {:DOWN, _ref, :process, _pid, _reason}, data) do
    Logger.info("dialog #{inspect(data.id)}: owner process terminated")
    {:stop, :normal}
  end

  def confirmed(event_type, event_content, data) do
    handle_event(event_type, event_content, data)
  end

  # Terminated state
  def terminated({:call, from}, :get_state, _data) do
    {:keep_state_and_data, [{:reply, from, :terminated}]}
  end

  def terminated({:call, from}, request, data) when request in [:get_dialog_id, :get_early_branch, :get_dialog_type, :get_dialog_info, :is_recovered?, :get_timing_data, :get_dialog_data] do
    result = handle_introspection_call(request, data)
    {:keep_state_and_data, [{:reply, from, result}]}
  end

  def terminated(_, _, _data) do
    {:stop, :normal}
  end

  # Private Functions

  # Handle introspection calls for public API
  defp handle_introspection_call(:get_dialog_id, %Data{id: id}) do
    {:ok, id}
  end

  defp handle_introspection_call(:get_early_branch, %Data{early_branch: early_branch}) do
    {:ok, early_branch}
  end

  defp handle_introspection_call(:get_dialog_type, %Data{dialog_type: dialog_type}) do
    {:ok, dialog_type}
  end

  defp handle_introspection_call(:get_dialog_info, %Data{dialog: nil}) do
    {:ok, %{id: nil, call_id: nil, state: nil, local_tag: nil, remote_tag: nil}}
  end

  defp handle_introspection_call(:get_dialog_info, %Data{dialog: dialog}) do
    {:ok, %{
      id: dialog.id,
      call_id: dialog.call_id,
      state: dialog.state,
      local_tag: dialog.local_tag,
      remote_tag: dialog.remote_tag
    }}
  end

  defp handle_introspection_call(:is_recovered?, %Data{recovered: recovered}) do
    {:ok, recovered}
  end

  defp handle_introspection_call(:get_timing_data, %Data{invite_received_at: invite_received_at, answered_at: answered_at}) do
    {:ok, %{invite_received_at: invite_received_at, answered_at: answered_at}}
  end

  defp handle_introspection_call(:get_dialog_data, %Data{dialog: dialog}) do
    {:ok, dialog}
  end

  defp process_uas_request(state, req_sip_msg, data, from) do
    # Process the request in the dialog
    case Dialog.uas_process(req_sip_msg, data.dialog) do
      {:ok, updated_dialog} ->
        updated_data = %{data | dialog: updated_dialog}

        # Check if dialog should transition states
        new_state = if updated_dialog.state == :terminated, do: :terminated, else: state

        # Broadcast delete when dialog terminates
        if new_state == :terminated do
          maybe_broadcast_delete(data.id)
        end

        {:next_state, new_state, updated_data, [{:reply, from, :process}]}

      {:error, :cseq_out_of_order} ->
        Logger.warning("dialog #{inspect(data.id)}: rejecting out-of-order CSeq")
        # Send 500 response for out-of-order CSeq per RFC 3261
        error_response = Message.reply(req_sip_msg, 500, "Server Internal Error")
        {:keep_state_and_data, [{:reply, from, {:reply, error_response}}]}

      {:error, reason} ->
        Logger.error(
          "dialog #{inspect(data.id)}: failed to process UAS request: #{inspect(reason)}"
        )

        # Send generic error response
        error_response = Message.reply(req_sip_msg, 500, "Server Internal Error")
        {:keep_state_and_data, [{:reply, from, {:reply, error_response}}]}
    end
  end

  defp process_uas_response(:early, %Message{status_code: status_code}, _req_sip_msg, data)
       when status_code >= 200 and status_code < 300 do
    # Capture answered_at timestamp for CDR when transitioning to confirmed
    data = %{data | answered_at: DateTime.utc_now()}

    # Broadcast dialog creation when transitioning to confirmed
    broadcast_state = %{
      call_id: data.dialog.call_id,
      local_tag: data.dialog.local_tag,
      remote_tag: data.dialog.remote_tag,
      state: :confirmed,
      owner_node: node()
    }

    maybe_broadcast_create(data.id, broadcast_state)

    {:next_state, :confirmed, data}
  end

  defp process_uas_response(state, _resp_sip_msg, _req_sip_msg, data) do
    {:next_state, state, data}
  end

  defp process_uac_trans_result(state, {:message, resp_sip_msg}, data) do
    # Process response in dialog context
    # Dialog.uac_response always returns {:ok, updated_dialog}
    {:ok, updated_dialog} = Dialog.uac_response(resp_sip_msg, data.dialog)
    updated_data = %{data | dialog: updated_dialog}

    # Check state transitions
    new_state = determine_new_state(state, updated_dialog.state)

    # Capture answered_at timestamp for CDR when transitioning from early to confirmed
    updated_data =
      if state == :early and new_state == :confirmed do
        %{updated_data | answered_at: DateTime.utc_now()}
      else
        updated_data
      end

    # Broadcast dialog creation when transitioning from early to confirmed
    if state == :early and new_state == :confirmed do
      broadcast_state = %{
        call_id: updated_dialog.call_id,
        local_tag: updated_dialog.local_tag,
        remote_tag: updated_dialog.remote_tag,
        state: :confirmed,
        owner_node: node()
      }

      maybe_broadcast_create(data.id, broadcast_state)
    end

    # Broadcast update for any state change in confirmed state
    if state == :confirmed and updated_dialog.state == :confirmed do
      maybe_broadcast_update(data.id, %{})
    end

    {:next_state, new_state, updated_data}
  end

  defp process_uac_trans_result(_state, {:stop, _reason}, _data) do
    {:stop, :normal}
  end

  defp determine_new_state(_current, :terminated), do: :terminated
  defp determine_new_state(:early, :confirmed), do: :confirmed
  defp determine_new_state(current, _), do: current

  defp process_uac_request(_state, req_sip_msg, data, from) do
    # Create in-dialog request
    # Dialog.uac_request always returns {:ok, request, updated_dialog}
    # Pass the full message template (with other_headers) if available
    {:ok, request, updated_dialog} = Dialog.uac_request(req_sip_msg, data.dialog)
    updated_data = %{data | dialog: updated_dialog}
    {:keep_state, updated_data, [{:reply, from, {:ok, request}}]}
  end

  defp process_set_owner(_state, pid, data) do
    # Monitor the owner process
    # Demonitor old owner and flush any pending DOWN messages
    if data.owner_mon do
      Process.demonitor(data.owner_mon, [:flush])
    end

    mon = Process.monitor(pid)
    updated_data = %{data | owner_mon: mon}

    {:keep_state, updated_data}
  end

  defp handle_event(:enter, _old_state, _data) do
    :keep_state_and_data
  end

  defp handle_event({:call, from}, event_content, data) do
    Logger.warning("dialog #{inspect(data.id)}: unexpected call: #{inspect(event_content)}")
    # Reply with an error for unexpected calls
    {:keep_state_and_data, [{:reply, from, {:error, :unexpected_call}}]}
  end

  defp handle_event(event_type, event_content, data) do
    Logger.warning(
      "dialog #{inspect(data.id)}: unexpected event #{inspect(event_type)}: #{inspect(event_content)}"
    )

    :keep_state_and_data
  end

  # Helper functions

  defp dialog_registry_key(
         {:uas, %Message{to: %{parameters: %{"tag" => to_tag}}},
          %Message{
            from: %{parameters: %{"tag" => from_tag}},
            call_id: call_id
          }}
       ) do
    # For UAS: local=to_tag, remote=from_tag
    dialog_id_str = Dialog.generate_id(:uas, call_id, to_tag, from_tag)
    {:dialog, dialog_id_str}
  end

  defp dialog_registry_key(
         {:uac,
          %Message{
            from: %{parameters: %{"tag" => from_tag}},
            call_id: call_id
          }, %Message{to: %{parameters: %{"tag" => to_tag}}}}
       ) do
    # For UAC: local=from_tag, remote=to_tag
    dialog_id_str = Dialog.generate_id(:uac, call_id, from_tag, to_tag)
    {:dialog, dialog_id_str}
  end

  defp dialog_type(%Message{method: :notify}), do: :notify
  defp dialog_type(%Message{method: :subscribe}), do: :notify
  defp dialog_type(%Message{method: _}), do: :invite

  defp uas_log_id(%Message{method: method, call_id: call_id}) do
    "#{method} #{call_id}"
  end

  defp uac_log_id(%Message{type: :request, method: method, call_id: call_id}) do
    "#{method} #{call_id}"
  end

  defp uac_log_id(%Message{type: :response, call_id: call_id}) do
    "response #{call_id}"
  end

  defp uac_log_id(%Message{method: method, call_id: call_id}) do
    "#{method} #{call_id}"
  end

  defp get_expires(%Message{expires: expires}, _default) when is_integer(expires) do
    expires
  end

  defp get_expires(%Message{expires: expires}, default) when is_binary(expires) do
    case Integer.parse(expires) do
      {val, _} -> val
      :error -> default
    end
  end

  defp get_expires(%Message{}, default) do
    default
  end

  defp get_branch_from_request(%Message{via: %Via{parameters: %{"branch" => branch}}}) do
    branch
  end

  defp get_branch_from_request(%Message{via: [%Via{parameters: %{"branch" => branch}} | _]}) do
    branch
  end

  defp get_branch_from_request(%Message{}) do
    Branch.generate()
  end

  # RFC 3261 Section 8.1.1: Validate required headers
  defp uas_validate_request(%Message{to: nil} = sip_msg) do
    {:reply, Message.reply(sip_msg, 400, "Missing To header")}
  end

  defp uas_validate_request(%Message{from: nil} = sip_msg) do
    {:reply, Message.reply(sip_msg, 400, "Missing From header")}
  end

  defp uas_validate_request(%Message{call_id: nil} = sip_msg) do
    {:reply, Message.reply(sip_msg, 400, "Missing Call-ID header")}
  end

  defp uas_validate_request(%Message{cseq: nil} = sip_msg) do
    {:reply, Message.reply(sip_msg, 400, "Missing CSeq header")}
  end

  defp uas_validate_request(%Message{via: []} = sip_msg) do
    {:reply, Message.reply(sip_msg, 400, "Missing Via header")}
  end

  # RFC 3261 Section 8.1.1.5: Check Max-Forwards to prevent loops
  defp uas_validate_request(%Message{max_forwards: 0} = sip_msg) do
    {:reply, Message.reply(sip_msg, 483, "Too Many Hops")}
  end

  # All validations passed
  defp uas_validate_request(%Message{}) do
    :process
  end

  defp uas_maybe_create_dialog(%Message{} = resp_sip_msg, %Message{} = req_sip_msg) do
    # Check if this response creates a dialog
    if should_create_dialog?(resp_sip_msg, req_sip_msg) do
      Logger.info(
        "Creating dialog for #{req_sip_msg.method} response #{resp_sip_msg.status_code}"
      )

      # Start a new dialog
      case ParrotSip.Dialog.Supervisor.start_child({:uas, resp_sip_msg, req_sip_msg}) do
        {:ok, pid} ->
          Logger.info("Dialog created successfully with PID: #{inspect(pid)}")
          resp_sip_msg

        {:error, reason} ->
          Logger.error("Failed to create dialog: #{inspect(reason)}")
          resp_sip_msg
      end
    else
      Logger.debug(
        "Not creating dialog for #{req_sip_msg.method} response #{resp_sip_msg.status_code}"
      )

      resp_sip_msg
    end
  end

  # RFC 3261 Section 12.1.1: Dialogs are created by:
  # 1. 2xx responses to INVITE or SUBSCRIBE (confirmed dialog)
  # 2. 1xx responses to INVITE with to-tag (early dialog)

  # Early dialog: 1xx response to INVITE with to-tag
  defp should_create_dialog?(
         %Message{status_code: code, to: %{parameters: %{"tag" => _}}},
         %Message{method: :invite}
       )
       when code >= 100 and code < 200 do
    Logger.debug("should_create_dialog? early dialog: INVITE 1xx with to-tag")
    true
  end

  # Confirmed dialog: 2xx response to INVITE or SUBSCRIBE
  defp should_create_dialog?(
         %Message{status_code: code},
         %Message{method: method}
       )
       when code >= 200 and code < 300 and method in [:invite, :subscribe] do
    Logger.debug("should_create_dialog? confirmed: #{method} 2xx")
    true
  end

  # All other cases - no dialog
  defp should_create_dialog?(%Message{status_code: code}, %Message{method: method}) do
    Logger.debug("should_create_dialog? no: status=#{code}, method=#{method}")
    false
  end

  defp uas_pass_response(dialog_pid, resp_sip_msg, req_sip_msg) do
    :gen_statem.cast(dialog_pid, {:uas_response, resp_sip_msg, req_sip_msg})
    resp_sip_msg
  end

  defp uac_no_dialog_result(%Message{} = out_req, {:message, resp_sip_msg}) do
    # Check if this response creates a dialog
    if should_create_dialog?(resp_sip_msg, out_req) do
      start_uac_dialog(out_req, resp_sip_msg)
    end

    :ok
  end

  defp start_uac_dialog(out_req, resp_sip_msg) do
    case ParrotSip.Dialog.Supervisor.start_child({:uac, out_req, resp_sip_msg}) do
      {:ok, _pid} ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to create dialog: #{inspect(reason)}")
        :ok
    end
  end

  defp uac_trans_result(dialog_pid, trans_result) do
    :gen_statem.cast(dialog_pid, {:uac_trans_result, trans_result})
    :ok
  end

  # ===========================================================================
  # gen_statem terminate callback - CDR generation
  # ===========================================================================

  @doc """
  Generates and dispatches CDR when dialog terminates.

  RFC 3261 Section 12.3: Termination of a Dialog

  Called by gen_statem for all termination paths:
  - BYE request processed (normal call end)
  - Transaction stop signal
  - Owner process dies
  - Subscription expired

  Only generates CDRs for INVITE dialogs (not SUBSCRIBE/NOTIFY).
  Dispatches to handlers asynchronously to avoid blocking termination.
  """
  @impl :gen_statem
  def terminate(reason, state, data) do
    # Only generate CDR for INVITE dialogs with valid dialog data
    if data.dialog_type == :invite and data.dialog != nil do
      generate_and_dispatch_cdr(data, state, reason)
    end

    :ok
  end

  # Generates CDR and dispatches to all registered handlers asynchronously.
  # Errors are logged but do not affect dialog termination.
  @spec generate_and_dispatch_cdr(Data.t(), atom(), term()) :: :ok
  defp generate_and_dispatch_cdr(data, state, reason) do
    # Build termination cause based on how dialog ended
    termination_cause = build_termination_cause(data, state, reason)

    # Build timing data - ended_at is captured now at termination
    timing_data = %{
      invite_received_at: data.invite_received_at,
      answered_at: data.answered_at,
      ended_at: DateTime.utc_now()
    }

    # Generate CDR
    case Generator.generate(data.dialog, timing_data, termination_cause) do
      {:ok, cdr} ->
        # Fire-and-forget dispatch to all handlers
        handlers = CDR.list_handlers()

        if handlers != [] do
          Logger.debug("dialog #{inspect(data.id)}: dispatching CDR to #{length(handlers)} handlers")
          Dispatcher.dispatch(cdr, handlers)
        else
          Logger.debug("dialog #{inspect(data.id)}: no CDR handlers registered")
        end

        :ok

      {:error, reason} ->
        Logger.warning("dialog #{inspect(data.id)}: failed to generate CDR: #{inspect(reason)}")
        :ok
    end
  end

  # Builds termination cause based on dialog state and termination context.
  # Determines disposition based on whether call was answered and how it ended.
  @spec build_termination_cause(Data.t(), atom(), term()) :: TerminationCause.t()
  defp build_termination_cause(data, state, _reason) do
    cond do
      # Call was answered (has answered_at) - normal termination via BYE
      data.answered_at != nil ->
        %TerminationCause{
          party: :caller,
          sip_code: 200,
          reason: "BYE",
          method: :bye
        }

      # Early state - call was cancelled or rejected before answer
      state == :early ->
        %TerminationCause{
          party: :caller,
          sip_code: 487,
          reason: "Request Terminated",
          method: :cancel
        }

      # Default - system termination (owner died, timeout, etc.)
      true ->
        %TerminationCause{
          party: :system,
          sip_code: 500,
          reason: "Dialog Terminated",
          method: nil
        }
    end
  end

  # DialogBroadcast integration helpers
  # These functions provide graceful degradation if DialogBroadcast is not running

  defp maybe_broadcast_create(dialog_id, state) do
    case Process.whereis(:dialog_broadcast) do
      nil ->
        Logger.debug("dialog #{dialog_id}: DialogBroadcast not running, skipping broadcast")
        :ok

      pid ->
        DialogBroadcast.broadcast_create(pid, dialog_id, state)
    end
  end

  defp maybe_broadcast_update(dialog_id, changes) do
    case Process.whereis(:dialog_broadcast) do
      nil ->
        Logger.debug("dialog #{dialog_id}: DialogBroadcast not running, skipping broadcast")
        :ok

      pid ->
        DialogBroadcast.broadcast_update(pid, dialog_id, changes)
    end
  end

  defp maybe_broadcast_delete(dialog_id) do
    case Process.whereis(:dialog_broadcast) do
      nil ->
        Logger.debug("dialog #{dialog_id}: DialogBroadcast not running, skipping broadcast")
        :ok

      pid ->
        DialogBroadcast.broadcast_delete(pid, dialog_id)
    end
  end
end
