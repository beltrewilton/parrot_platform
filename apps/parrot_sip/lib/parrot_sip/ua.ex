defmodule ParrotSip.UA do
  @moduledoc """
  High-level User Agent for building SIP applications.

  The UA provides a clean, callback-driven API for softphones, auto-attendants,
  and B2BUA softswitches. It manages entities (call legs) and translates low-level
  SIP events into application-level callbacks.

  ## Example

      defmodule MyPhone do
        use ParrotSip.UA.Handler

        def init(_) do
          {:ok, %{}}
        end

        def handle_incoming(ua, invite, entity, state) do
          ParrotSip.UA.answer(ua, entity, sdp: generate_sdp())
          {:ok, state}
        end

        def handle_answered(_ua, _response, entity, state) do
          IO.puts("Connected to \#{entity.remote_uri}")
          {:ok, state}
        end

        def handle_hangup(_ua, _message, _entity, state) do
          {:ok, state}
        end
      end

      # Start UA
      {:ok, ua} = ParrotSip.UA.start_link(MyPhone, nil, port: 5060)

      # Make a call
      {:ok, entity} = ParrotSip.UA.dial(ua, "sip:bob@example.com", sdp: my_sdp)
  """

  use GenServer
  require Logger

  alias ParrotSip.{Message, Handler, Source}
  alias ParrotSip.UA.Entity
  alias ParrotSip.Transaction.{Client, Server}
  alias ParrotSip.Headers.{From, To, CSeq, Contact, Via}

  @behaviour Handler

  defstruct [
    :handler_module,
    :handler_state,
    :entities,
    :registrations,
    :port,
    :transport,
    :local_host
  ]

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Starts a UA GenServer.

  ## Parameters
  - `handler_module` - Module implementing ParrotSip.UA.Handler
  - `init_arg` - Passed to handler's init/1
  - `opts` - Options including `:port`, `:transport`, `:name`

  ## Examples

      {:ok, ua} = ParrotSip.UA.start_link(MyHandler, nil, port: 5060)
  """
  def start_link(handler_module, init_arg, opts \\ []) do
    {gen_opts, ua_opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, {handler_module, init_arg, ua_opts}, gen_opts)
  end

  @doc """
  Make an outbound call.

  Returns a client entity representing the outbound call leg.

  ## Options
  - `:sdp` - SDP body for the INVITE
  - `:headers` - Additional headers

  ## Examples

      {:ok, entity} = ParrotSip.UA.dial(ua, "sip:bob@example.com", sdp: my_sdp)
  """
  def dial(ua, uri, opts \\ []) do
    GenServer.call(ua, {:dial, uri, opts})
  end

  @doc """
  Answer an incoming call.

  ## Options
  - `:sdp` - SDP body for 200 OK

  ## Examples

      :ok = ParrotSip.UA.answer(ua, entity, sdp: my_sdp)
  """
  def answer(_ua, %Entity{uas: uas, request: request, ua_pid: ua_pid} = entity, opts \\ []) do
    sdp = Keyword.get(opts, :sdp, "")
    response = Message.reply(request, 200, "OK")
    response = %{response | body: sdp}
    Server.response(response, uas)
    GenServer.cast(ua_pid, {:entity_state_change, entity.id, :confirmed})
    :ok
  end

  @doc """
  Send 180 Ringing for an incoming call.
  """
  def ring(_ua, %Entity{uas: uas, request: request}) do
    response = Message.reply(request, 180, "Ringing")
    Server.response(response, uas)
    :ok
  end

  @doc """
  Reject an incoming call.

  ## Examples

      :ok = ParrotSip.UA.reject(ua, entity, 486, "Busy Here")
  """
  def reject(_ua, %Entity{uas: uas, request: request, ua_pid: ua_pid} = entity, status, reason) do
    response = Message.reply(request, status, reason)
    Server.response(response, uas)
    GenServer.cast(ua_pid, {:entity_state_change, entity.id, :terminated})
    :ok
  end

  @doc """
  End a call (send BYE).
  """
  def hangup(ua, %Entity{} = entity) do
    GenServer.call(ua, {:hangup, entity})
  end

  @doc """
  Cancel an outbound call before it's answered.
  """
  def cancel(ua, %Entity{} = entity) do
    GenServer.call(ua, {:cancel, entity})
  end

  @doc """
  Send UPDATE request within an established dialog.

  RFC 3311 - The Session Initiation Protocol (SIP) UPDATE Method

  UPDATE allows modifying session parameters mid-call without affecting the
  dialog state. Common use cases include:
  - Changing codecs or media parameters (with SDP)
  - Refreshing session timers (without SDP)
  - Updating session description during early dialog

  ## Options
  - `:sdp` - SDP body for the UPDATE (optional)
  - `:headers` - Additional headers map (optional)

  ## Examples

      # UPDATE with new SDP offer
      :ok = ParrotSip.UA.send_update(ua, entity, sdp: new_sdp)

      # Session timer refresh (no SDP)
      :ok = ParrotSip.UA.send_update(ua, entity, headers: %{"Session-Expires" => "1800"})
  """
  @spec send_update(pid(), Entity.t(), keyword()) :: :ok | {:error, term()}
  def send_update(ua, %Entity{} = entity, opts \\ []) do
    GenServer.call(ua, {:send_update, entity.id, opts})
  end

  @doc """
  Register with a SIP registrar.

  ## Options
  - `:expires` - Registration expiry in seconds (default: 3600)

  ## Examples

      {:ok, reg_id} = ParrotSip.UA.register(ua, "sip:registrar.example.com", expires: 3600)
  """
  def register(ua, registrar, opts \\ []) do
    GenServer.call(ua, {:register, registrar, opts})
  end

  @doc """
  Get the Handler struct for this UA.

  Used when starting a SIP stack that should route to this UA.
  """
  def get_handler(ua) do
    Handler.new(__MODULE__, %{ua_pid: ua})
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init({handler_module, init_arg, opts}) do
    case handler_module.init(init_arg) do
      {:ok, handler_state} ->
        state = %__MODULE__{
          handler_module: handler_module,
          handler_state: handler_state,
          entities: %{},
          registrations: %{},
          port: Keyword.get(opts, :port, 5060),
          transport: Keyword.get(opts, :transport, :udp),
          local_host: Keyword.get(opts, :local_host, "127.0.0.1")
        }

        # Schedule entity garbage collection
        schedule_entity_cleanup()

        {:ok, state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  # ============================================================================
  # Handler Behaviour Implementation (Low-level SIP callbacks)
  # ============================================================================

  @impl Handler
  def transp_request(_msg, _args), do: :process_transaction

  @impl Handler
  def transaction(_trans, _sip_msg, _args), do: :process_uas

  @impl Handler
  def transaction_stop(_trans, _result, _args), do: :ok

  @impl Handler
  def uas_request(_uas, _sip_msg, _args), do: :ok

  @impl Handler
  def uas_cancel(_uas_id, _args), do: :ok

  @impl Handler
  def process_ack(_sip_msg, _args), do: :ok

  @impl Handler
  def handle_invite(uas, %Message{} = invite, %{ua_pid: ua_pid}) do
    GenServer.call(ua_pid, {:incoming_invite, uas, invite})
  end

  @impl Handler
  def handle_bye(uas, %Message{} = bye, %{ua_pid: ua_pid}) do
    GenServer.call(ua_pid, {:incoming_bye, uas, bye})
  end

  @impl Handler
  def handle_cancel(_uas, %Message{} = cancel, %{ua_pid: ua_pid}) do
    GenServer.cast(ua_pid, {:incoming_cancel, cancel})
    :ok
  end

  @impl Handler
  def handle_options(uas, %Message{} = options, _args) do
    response = Message.reply(options, 200, "OK")
    Server.response(response, uas)
    :ok
  end

  @impl Handler
  def handle_register(uas, %Message{} = register, _args) do
    response = Message.reply(register, 200, "OK")
    Server.response(response, uas)
    :ok
  end

  # ============================================================================
  # GenServer handle_call
  # ============================================================================

  @impl true
  def handle_call({:dial, uri, opts}, _from, state) do
    # Build INVITE
    invite = build_invite(uri, opts, state)

    # Create entity with CSeq tracking (RFC 3261 Section 12.2.1.1)
    entity = %Entity{
      id: Entity.generate_id(),
      type: :client,
      state: :trying,
      remote_uri: uri,
      local_uri: "sip:user@#{state.local_host}:#{state.port}",
      call_id: invite.call_id,
      local_tag: invite.from.parameters["tag"],
      remote_tag: nil,
      local_seq: invite.cseq.number,
      created_at: System.monotonic_time(:millisecond),
      ua_pid: self(),
      request: invite
    }

    # Send via Transaction.Client
    ua_pid = self()

    {:uac_id, trans} =
      Client.request(invite, fn result ->
        GenServer.cast(ua_pid, {:uac_response, entity.id, result})
      end)

    # Store entity with transaction
    entity = %{entity | trans: trans}
    entities = Map.put(state.entities, entity.id, entity)

    {:reply, {:ok, entity}, %{state | entities: entities}}
  end

  def handle_call({:incoming_invite, uas, invite}, _from, state) do
    # Create server entity with CSeq tracking (RFC 3261 Section 12.2.1.1)
    # For UAS, local_seq starts at 0 (no requests sent yet)
    entity = %Entity{
      id: Entity.generate_id(),
      type: :server,
      state: :early,
      remote_uri: ParrotSip.Uri.to_string(invite.from.uri),
      local_uri: ParrotSip.Uri.to_string(invite.to.uri),
      call_id: invite.call_id,
      local_tag: generate_tag(),
      remote_tag: invite.from.parameters["tag"],
      local_seq: 0,
      created_at: System.monotonic_time(:millisecond),
      ua_pid: self(),
      uas: uas,
      request: invite
    }

    # Store entity
    entities = Map.put(state.entities, entity.id, entity)
    state = %{state | entities: entities}

    # Call user handler
    {:ok, new_handler_state} =
      state.handler_module.handle_incoming(self(), invite, entity, state.handler_state)

    {:reply, :ok, %{state | handler_state: new_handler_state}}
  end

  def handle_call({:incoming_bye, uas, bye}, _from, state) do
    # Find entity by call_id
    entity = find_entity_by_call_id(state.entities, bye.call_id)

    if entity do
      # Send 200 OK
      response = Message.reply(bye, 200, "OK")
      Server.response(response, uas)

      # Update entity state
      entity = %{entity | state: :terminated}
      entities = Map.put(state.entities, entity.id, entity)

      # Call user handler
      {:ok, new_handler_state} =
        state.handler_module.handle_hangup(self(), bye, entity, state.handler_state)

      {:reply, :ok, %{state | entities: entities, handler_state: new_handler_state}}
    else
      # Unknown call, still respond
      response = Message.reply(bye, 200, "OK")
      Server.response(response, uas)
      {:reply, :ok, state}
    end
  end

  def handle_call({:hangup, %Entity{id: entity_id}}, _from, state) do
    case Map.get(state.entities, entity_id) do
      nil ->
        {:reply, {:error, :entity_not_found}, state}

      entity ->
        # Increment CSeq per RFC 3261 Section 12.2.1.1
        next_seq = entity.local_seq + 1

        # Build and send BYE with proper CSeq
        bye = build_bye(entity, next_seq, state)

        ua_pid = self()

        {:uac_id, _trans} =
          Client.request(bye, fn result ->
            GenServer.cast(ua_pid, {:bye_response, entity_id, result})
          end)

        # Update entity state and local_seq
        entity = %{entity | state: :terminated, local_seq: next_seq}
        entities = Map.put(state.entities, entity_id, entity)

        {:reply, :ok, %{state | entities: entities}}
    end
  end

  def handle_call({:cancel, %Entity{id: entity_id, trans: trans}}, _from, state) do
    # Send CANCEL via transaction layer
    Client.cancel({:uac_id, trans})

    # Update entity state
    case Map.get(state.entities, entity_id) do
      nil ->
        {:reply, :ok, state}

      entity ->
        entity = %{entity | state: :terminated}
        entities = Map.put(state.entities, entity_id, entity)
        {:reply, :ok, %{state | entities: entities}}
    end
  end

  def handle_call({:register, registrar, opts}, _from, state) do
    # Build REGISTER
    register_msg = build_register(registrar, opts, state)
    reg_id = Entity.generate_id()

    ua_pid = self()

    {:uac_id, _trans} =
      Client.request(register_msg, fn result ->
        GenServer.cast(ua_pid, {:register_response, reg_id, result})
      end)

    # Track registration
    registrations = Map.put(state.registrations, reg_id, %{registrar: registrar, state: :pending})

    {:reply, {:ok, reg_id}, %{state | registrations: registrations}}
  end

  # RFC 3311: Send UPDATE request within dialog
  def handle_call({:send_update, entity_id, opts}, _from, state) do
    case Map.get(state.entities, entity_id) do
      nil ->
        {:reply, {:error, :entity_not_found}, state}

      %Entity{state: entity_state} when entity_state not in [:confirmed, :early] ->
        # UPDATE can be sent in confirmed or early dialog state
        {:reply, {:error, :invalid_state}, state}

      entity ->
        # Increment CSeq per RFC 3261 Section 12.2.1.1
        next_seq = entity.local_seq + 1
        sdp = Keyword.get(opts, :sdp)
        headers = Keyword.get(opts, :headers, %{})

        # Build and send UPDATE
        update = build_update(entity, next_seq, sdp, headers, state)

        ua_pid = self()

        {:uac_id, _trans} =
          Client.request(update, fn result ->
            GenServer.cast(ua_pid, {:update_response, entity_id, result})
          end)

        # Update entity's local_seq
        entity = %{entity | local_seq: next_seq}
        entities = Map.put(state.entities, entity_id, entity)

        {:reply, :ok, %{state | entities: entities}}
    end
  end

  # ============================================================================
  # GenServer handle_cast
  # ============================================================================

  @impl true
  def handle_cast({:entity_state_change, entity_id, new_state}, state) do
    case Map.get(state.entities, entity_id) do
      nil ->
        {:noreply, state}

      entity ->
        entity = %{entity | state: new_state}
        entities = Map.put(state.entities, entity_id, entity)
        {:noreply, %{state | entities: entities}}
    end
  end

  def handle_cast({:incoming_cancel, cancel}, state) do
    # Find entity by call_id
    entity = find_entity_by_call_id(state.entities, cancel.call_id)

    if entity do
      # Update entity state
      entity = %{entity | state: :terminated}
      entities = Map.put(state.entities, entity.id, entity)

      # Call user handler
      {:ok, new_handler_state} =
        state.handler_module.handle_cancel(self(), entity, state.handler_state)

      {:noreply, %{state | entities: entities, handler_state: new_handler_state}}
    else
      {:noreply, state}
    end
  end

  # UAC response - 180 Ringing
  def handle_cast(
        {:uac_response, entity_id, {:response, %Message{status_code: code} = response}},
        state
      )
      when code in 180..189 do
    case Map.get(state.entities, entity_id) do
      nil ->
        {:noreply, state}

      entity ->
        # Update entity state
        entity = %{entity | state: :early}
        entities = Map.put(state.entities, entity_id, entity)

        # Call user handler
        {:ok, new_handler_state} =
          state.handler_module.handle_ringing(self(), response, entity, state.handler_state)

        {:noreply, %{state | entities: entities, handler_state: new_handler_state}}
    end
  end

  # UAC response - 2xx Success
  def handle_cast(
        {:uac_response, entity_id, {:response, %Message{status_code: code} = response}},
        state
      )
      when code >= 200 and code < 300 do
    case Map.get(state.entities, entity_id) do
      nil ->
        {:noreply, state}

      entity ->
        # Update entity with remote tag and state
        remote_tag = response.to && response.to.parameters["tag"]

        entity = %{entity | state: :confirmed, remote_tag: remote_tag}
        entities = Map.put(state.entities, entity_id, entity)

        # Call user handler
        {:ok, new_handler_state} =
          state.handler_module.handle_answered(self(), response, entity, state.handler_state)

        {:noreply, %{state | entities: entities, handler_state: new_handler_state}}
    end
  end

  # UAC response - 3xx Redirect (MUST come before >= 300 pattern)
  # RFC 3261 Section 21: Redirect classes (300-399)
  def handle_cast(
        {:uac_response, entity_id, {:response, %Message{status_code: code} = response}},
        state
      )
      when code >= 300 and code < 400 do
    case Map.get(state.entities, entity_id) do
      nil ->
        {:noreply, state}

      entity ->
        # Extract and sort Contact headers by q-value (highest first)
        # Contacts without q-value default to q=1.0 per RFC 3261
        contacts = normalize_contacts(response.contact)

        sorted_contacts =
          Enum.sort_by(contacts, fn contact ->
            # Get q-value, defaulting to 1.0 if not present
            case Contact.q(contact) do
              nil -> 1.0
              q -> q
            end
          end, :desc)

        # Call user handler
        case state.handler_module.handle_redirect(
               self(),
               code,
               response,
               sorted_contacts,
               state.handler_state
             ) do
          {:redirect, _selected_contact, new_handler_state} ->
            # TODO: Implement actual redirect retry logic
            # For now, just update state - full redirect implementation
            # would create new INVITE to selected contact
            {:noreply, %{state | handler_state: new_handler_state}}

          {:stop, _reason, new_handler_state} ->
            # Terminate the entity
            entity = %{entity | state: :terminated}
            entities = Map.put(state.entities, entity_id, entity)
            {:noreply, %{state | entities: entities, handler_state: new_handler_state}}
        end
    end
  end

  # UAC response - 4xx-6xx Failure
  def handle_cast(
        {:uac_response, entity_id, {:response, %Message{status_code: code} = response}},
        state
      )
      when code >= 400 do
    case Map.get(state.entities, entity_id) do
      nil ->
        {:noreply, state}

      entity ->
        # Update entity state
        entity = %{entity | state: :terminated}
        entities = Map.put(state.entities, entity_id, entity)

        # Call user handler
        {:ok, new_handler_state} =
          state.handler_module.handle_rejected(self(), response, entity, state.handler_state)

        {:noreply, %{state | entities: entities, handler_state: new_handler_state}}
    end
  end

  # UAC response - Other (1xx, timeout, etc.)
  def handle_cast({:uac_response, _entity_id, _result}, state) do
    {:noreply, state}
  end

  # BYE response
  def handle_cast({:bye_response, _entity_id, _result}, state) do
    {:noreply, state}
  end

  # Register response - Success
  def handle_cast(
        {:register_response, reg_id, {:response, %Message{status_code: code} = response}},
        state
      )
      when code >= 200 and code < 300 do
    # Update registration state
    registrations =
      Map.update(state.registrations, reg_id, %{state: :registered}, fn reg ->
        %{reg | state: :registered}
      end)

    # Call user handler
    {:ok, new_handler_state} =
      state.handler_module.handle_registered(self(), response, reg_id, state.handler_state)

    {:noreply, %{state | registrations: registrations, handler_state: new_handler_state}}
  end

  # Register response - Failure
  def handle_cast(
        {:register_response, reg_id, {:response, %Message{status_code: code} = response}},
        state
      )
      when code >= 300 do
    # Update registration state
    registrations =
      Map.update(state.registrations, reg_id, %{state: :failed}, fn reg ->
        %{reg | state: :failed}
      end)

    # Call user handler
    {:ok, new_handler_state} =
      state.handler_module.handle_registration_failed(
        self(),
        response,
        reg_id,
        state.handler_state
      )

    {:noreply, %{state | registrations: registrations, handler_state: new_handler_state}}
  end

  # Register response - Other
  def handle_cast({:register_response, _reg_id, _result}, state) do
    {:noreply, state}
  end

  # UPDATE response - 2xx Success (RFC 3311 Section 5.3)
  def handle_cast(
        {:update_response, entity_id, {:response, %Message{status_code: code} = response}},
        state
      )
      when code >= 200 and code < 300 do
    case Map.get(state.entities, entity_id) do
      nil ->
        {:noreply, state}

      entity ->
        # Call user handler
        {:ok, new_handler_state} =
          state.handler_module.handle_update_complete(self(), response, entity, state.handler_state)

        {:noreply, %{state | handler_state: new_handler_state}}
    end
  end

  # UPDATE response - 4xx-6xx Failure (RFC 3311 Section 5.3)
  def handle_cast(
        {:update_response, entity_id, {:response, %Message{status_code: code} = response}},
        state
      )
      when code >= 400 do
    case Map.get(state.entities, entity_id) do
      nil ->
        {:noreply, state}

      entity ->
        # Call user handler
        {:ok, new_handler_state} =
          state.handler_module.handle_update_failed(
            self(),
            code,
            response,
            entity,
            state.handler_state
          )

        {:noreply, %{state | handler_state: new_handler_state}}
    end
  end

  # UPDATE response - Other (1xx, timeout, etc.)
  def handle_cast({:update_response, _entity_id, _result}, state) do
    {:noreply, state}
  end

  # ============================================================================
  # GenServer handle_info
  # ============================================================================

  @impl true
  def handle_info(:cleanup_entities, state) do
    # Clean up terminated entities and entities older than max age
    # This prevents memory leaks from accumulating stale entities
    now = System.monotonic_time(:millisecond)
    max_age_ms = :timer.minutes(10)

    {removed, kept} =
      Map.split_with(state.entities, fn {_id, entity} ->
        entity.state == :terminated or
          (entity.created_at != nil and now - entity.created_at > max_age_ms)
      end)

    if map_size(removed) > 0 do
      Logger.debug("UA cleanup: removed #{map_size(removed)} stale entities")
    end

    schedule_entity_cleanup()
    {:noreply, %{state | entities: kept}}
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  # Schedule periodic entity garbage collection (every 1 minute)
  defp schedule_entity_cleanup do
    Process.send_after(self(), :cleanup_entities, :timer.minutes(1))
  end

  defp build_invite(uri, opts, state) do
    call_id = "#{Entity.generate_id()}@#{state.local_host}"
    from_tag = generate_tag()
    sdp = Keyword.get(opts, :sdp, "")
    dest_uri = ParrotSip.Uri.parse!(uri)
    {:ok, dest_ip} = :inet.parse_address(String.to_charlist(dest_uri.host))
    dest_port = dest_uri.port || 5060
    {:ok, local_ip} = :inet.parse_address(String.to_charlist(state.local_host))

    %Message{
      type: :request,
      method: :invite,
      request_uri: uri,
      version: "SIP/2.0",
      from: %From{
        display_name: nil,
        uri: "sip:user@#{state.local_host}:#{state.port}",
        parameters: %{"tag" => from_tag}
      },
      to: %To{
        display_name: nil,
        uri: uri,
        parameters: %{}
      },
      call_id: call_id,
      cseq: %CSeq{number: 1, method: :invite},
      contact: [
        %Contact{
          display_name: nil,
          uri: "sip:user@#{state.local_host}:#{state.port}",
          parameters: %{}
        }
      ],
      via: [
        %Via{
          protocol: "SIP",
          version: "2.0",
          transport: state.transport,
          host: state.local_host,
          port: state.port,
          parameters: %{}
        }
      ],
      max_forwards: 70,
      content_type: if(sdp != "", do: "application/sdp", else: nil),
      body: sdp,
      source: %Source{
        local: {local_ip, state.port},
        remote: {dest_ip, dest_port},
        transport: state.transport
      }
    }
  end

  # Build UPDATE with proper CSeq tracking per RFC 3311
  # Note: extra_headers parameter reserved for future use (Session-Expires, etc.)
  defp build_update(entity, cseq_number, sdp, _extra_headers, state) do
    dest_uri = ParrotSip.Uri.parse!(entity.remote_uri)
    {:ok, dest_ip} = :inet.parse_address(String.to_charlist(dest_uri.host))
    dest_port = dest_uri.port || 5060
    {:ok, local_ip} = :inet.parse_address(String.to_charlist(state.local_host))

    # RFC 3311 Section 5.1: UPDATE MUST contain Contact header
    %Message{
      type: :request,
      method: :update,
      request_uri: entity.remote_uri,
      version: "SIP/2.0",
      from: %From{
        display_name: nil,
        uri: entity.local_uri,
        parameters: %{"tag" => entity.local_tag}
      },
      to: %To{
        display_name: nil,
        uri: entity.remote_uri,
        parameters: %{"tag" => entity.remote_tag}
      },
      call_id: entity.call_id,
      cseq: %CSeq{number: cseq_number, method: :update},
      contact: [
        %Contact{
          display_name: nil,
          uri: "sip:user@#{state.local_host}:#{state.port}",
          parameters: %{}
        }
      ],
      via: [
        %Via{
          protocol: "SIP",
          version: "2.0",
          transport: state.transport,
          host: state.local_host,
          port: state.port,
          parameters: %{}
        }
      ],
      max_forwards: 70,
      content_type: if(sdp, do: "application/sdp", else: nil),
      body: sdp || "",
      source: %Source{
        local: {local_ip, state.port},
        remote: {dest_ip, dest_port},
        transport: state.transport
      }
    }
  end

  # Build BYE with proper CSeq tracking per RFC 3261 Section 12.2.1.1
  defp build_bye(entity, cseq_number, state) do
    dest_uri = ParrotSip.Uri.parse!(entity.remote_uri)
    {:ok, dest_ip} = :inet.parse_address(String.to_charlist(dest_uri.host))
    dest_port = dest_uri.port || 5060
    {:ok, local_ip} = :inet.parse_address(String.to_charlist(state.local_host))

    %Message{
      type: :request,
      method: :bye,
      request_uri: entity.remote_uri,
      version: "SIP/2.0",
      from: %From{
        display_name: nil,
        uri: entity.local_uri,
        parameters: %{"tag" => entity.local_tag}
      },
      to: %To{
        display_name: nil,
        uri: entity.remote_uri,
        parameters: %{"tag" => entity.remote_tag}
      },
      call_id: entity.call_id,
      cseq: %CSeq{number: cseq_number, method: :bye},
      via: [
        %Via{
          protocol: "SIP",
          version: "2.0",
          transport: state.transport,
          host: state.local_host,
          port: state.port,
          parameters: %{}
        }
      ],
      max_forwards: 70,
      source: %Source{
        local: {local_ip, state.port},
        remote: {dest_ip, dest_port},
        transport: state.transport
      }
    }
  end

  defp build_register(registrar, opts, state) do
    call_id = "#{Entity.generate_id()}@#{state.local_host}"
    from_tag = generate_tag()
    expires = Keyword.get(opts, :expires, 3600)
    dest_uri = ParrotSip.Uri.parse!(registrar)
    {:ok, dest_ip} = :inet.parse_address(String.to_charlist(dest_uri.host))
    dest_port = dest_uri.port || 5060
    {:ok, local_ip} = :inet.parse_address(String.to_charlist(state.local_host))

    %Message{
      type: :request,
      method: :register,
      request_uri: registrar,
      version: "SIP/2.0",
      from: %From{
        display_name: nil,
        uri: "sip:user@#{state.local_host}",
        parameters: %{"tag" => from_tag}
      },
      to: %To{
        display_name: nil,
        uri: "sip:user@#{state.local_host}",
        parameters: %{}
      },
      call_id: call_id,
      cseq: %CSeq{number: 1, method: :register},
      contact: [
        %Contact{
          display_name: nil,
          uri: "sip:user@#{state.local_host}:#{state.port}",
          parameters: %{}
        }
      ],
      via: [
        %Via{
          protocol: "SIP",
          version: "2.0",
          transport: state.transport,
          host: state.local_host,
          port: state.port,
          parameters: %{}
        }
      ],
      max_forwards: 70,
      expires: expires,
      source: %Source{
        local: {local_ip, state.port},
        remote: {dest_ip, dest_port},
        transport: state.transport
      }
    }
  end

  defp find_entity_by_call_id(entities, call_id) do
    entities
    |> Map.values()
    |> Enum.find(fn entity -> entity.call_id == call_id end)
  end

  defp generate_tag do
    Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
  end

  # Normalize contact header(s) to a list of Contact structs
  # The contact field can be nil, a single Contact, or a list of Contacts
  defp normalize_contacts(nil), do: []
  defp normalize_contacts(contacts) when is_list(contacts), do: contacts
  defp normalize_contacts(contact), do: [contact]
end
