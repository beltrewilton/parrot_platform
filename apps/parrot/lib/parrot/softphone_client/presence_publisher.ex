defmodule Parrot.SoftphoneClient.PresencePublisher do
  @moduledoc """
  Manages presence publication via SIP PUBLISH (RFC 3903).

  Handles:
  - Initial publication
  - Publication refresh
  - Publication modification
  - Publication removal (unpublish)

  ## Usage

      {:ok, pub} = PresencePublisher.start_link(
        config: config,
        notify_pid: self()
      )

      :ok = PresencePublisher.publish(pub, %{status: :open, note: "Available"})
      # Receive {:presence_event, :publish_success, %{}}

      :ok = PresencePublisher.publish(pub, %{status: :closed, note: "Away"})
      # Modifies existing publication

      :ok = PresencePublisher.unpublish(pub)
      # Removes publication

  ## Notifications

  Sends messages to `notify_pid`:
  - `{:presence_event, :publish_success, %{}}`
  - `{:presence_event, :publish_failed, reason}`
  """

  use GenServer

  require Logger

  # Refresh 60 seconds before expiry
  @refresh_buffer_seconds 60

  defstruct [
    :config,
    :notify_pid,
    :etag,
    :current_state,
    :pending_state,
    :refresh_timer,
    expires: 3600,
    refresh_scheduled: false,
    pending_refresh: false
  ]

  @type presence_state :: %{
          status: :open | :closed,
          note: String.t() | nil
        }

  @type t :: %__MODULE__{
          config: map(),
          notify_pid: pid() | nil,
          etag: String.t() | nil,
          current_state: presence_state() | nil,
          pending_state: presence_state() | nil,
          refresh_timer: reference() | nil,
          expires: non_neg_integer(),
          refresh_scheduled: boolean(),
          pending_refresh: boolean()
        }

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Start the presence publisher.

  ## Options

  - `:config` - Configuration map with username, domain
  - `:notify_pid` - PID to receive presence events
  - `:expires` - Default expiry in seconds (default: 3600)
  - `:name` - Optional name for the process
  """
  def start_link(opts) do
    {gen_opts, init_opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, init_opts, gen_opts)
  end

  @doc """
  Publish presence state.

  If no publication exists, creates a new one.
  If a publication exists, modifies it.
  """
  @spec publish(pid(), presence_state(), keyword()) :: :ok | {:error, term()}
  def publish(pid, state, opts \\ []) do
    GenServer.call(pid, {:publish, state, opts})
  end

  @doc """
  Refresh the current publication.

  Sends PUBLISH with SIP-If-Match header.
  """
  @spec refresh(pid()) :: :ok | {:error, term()}
  def refresh(pid) do
    GenServer.call(pid, :refresh)
  end

  @doc """
  Remove published presence (unpublish).

  Sends PUBLISH with Expires: 0.
  """
  @spec unpublish(pid()) :: :ok | {:error, term()}
  def unpublish(pid) do
    GenServer.call(pid, :unpublish)
  end

  @doc """
  Get current state (for testing).
  """
  def get_state(pid) do
    GenServer.call(pid, :get_state)
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(opts) do
    config = Keyword.fetch!(opts, :config)
    notify_pid = Keyword.fetch!(opts, :notify_pid)
    expires = Keyword.get(opts, :expires, 3600)

    state = %__MODULE__{
      config: config,
      notify_pid: notify_pid,
      expires: expires
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:publish, presence_state, _opts}, _from, state) do
    # Store pending state and initiate publish
    new_state = %{state | pending_state: presence_state}

    case send_publish(new_state) do
      :ok ->
        {:reply, :ok, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call(:refresh, _from, state) do
    if state.etag && state.current_state do
      new_state = %{state | pending_refresh: true, pending_state: state.current_state}

      case send_publish(new_state) do
        :ok ->
          {:reply, :ok, new_state}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    else
      {:reply, {:error, :nothing_to_refresh}, state}
    end
  end

  @impl true
  def handle_call(:unpublish, _from, state) do
    if state.etag do
      new_state = %{state | pending_state: nil}

      case send_unpublish(new_state) do
        :ok ->
          {:reply, :ok, new_state}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    else
      {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_info({:sip_response, %{status_code: code} = resp}, state)
      when code >= 200 and code < 300 do
    etag = extract_etag(resp)
    expires = extract_expires(resp)

    if expires == 0 do
      # Unpublish successful
      new_state =
        state
        |> cancel_refresh()
        |> Map.merge(%{
          etag: nil,
          current_state: nil,
          pending_state: nil,
          refresh_scheduled: false,
          pending_refresh: false
        })

      {:noreply, new_state}
    else
      # Publish/refresh successful
      new_state =
        state
        |> schedule_refresh(expires)
        |> Map.merge(%{
          etag: etag,
          current_state: state.pending_state,
          pending_state: nil,
          expires: expires,
          pending_refresh: false
        })

      notify_handler(:publish_success, %{}, state)
      {:noreply, new_state}
    end
  end

  @impl true
  def handle_info({:sip_response, %{status_code: code}}, state)
      when code >= 300 do
    notify_handler(:publish_failed, {:status, code}, state)

    new_state = %{state | pending_state: nil, pending_refresh: false}
    {:noreply, new_state}
  end

  @impl true
  def handle_info({:timeout, :publish_timeout}, state) do
    notify_handler(:publish_failed, :timeout, state)

    new_state = %{state | pending_state: nil, pending_refresh: false}
    {:noreply, new_state}
  end

  @impl true
  def handle_info(:refresh, state) do
    # Automatic refresh timer fired
    if state.etag && state.current_state do
      new_state = %{state | pending_refresh: true, pending_state: state.current_state}

      case send_publish(new_state) do
        :ok ->
          {:noreply, new_state}

        {:error, _reason} ->
          # Will retry on next timer
          {:noreply, state}
      end
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(msg, state) do
    Logger.warning("PresencePublisher: unexpected message #{inspect(msg)}")
    {:noreply, state}
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp send_publish(state) do
    # Validate config
    with {:ok, username} <- fetch_config(state.config, :username),
         {:ok, domain} <- fetch_config(state.config, :domain) do
      # Build PIDF+XML body
      pidf_body = build_pidf(username, domain, state.pending_state)

      # TODO: Actually send PUBLISH via ParrotSip
      # Headers:
      # - Event: presence
      # - Content-Type: application/pidf+xml
      # - Expires: <value>
      # - SIP-If-Match: <etag> (if refreshing/modifying)

      Logger.debug(
        "PresencePublisher: sending PUBLISH for #{username}@#{domain} " <>
          "etag=#{inspect(state.etag)} body_length=#{byte_size(pidf_body)}"
      )

      :ok
    end
  end

  defp send_unpublish(state) do
    with {:ok, username} <- fetch_config(state.config, :username),
         {:ok, domain} <- fetch_config(state.config, :domain) do
      # TODO: Actually send PUBLISH with Expires: 0 via ParrotSip
      # Headers:
      # - Event: presence
      # - Expires: 0
      # - SIP-If-Match: <etag>

      Logger.debug(
        "PresencePublisher: sending unpublish for #{username}@#{domain} " <>
          "etag=#{inspect(state.etag)}"
      )

      :ok
    end
  end

  defp fetch_config(config, key) do
    case Map.fetch(config, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      {:ok, value} when is_atom(value) and not is_nil(value) -> {:ok, value}
      _ -> {:error, {:missing_config, key}}
    end
  end

  defp build_pidf(username, domain, presence_state) when is_map(presence_state) do
    status = Map.get(presence_state, :status, :open)
    note = Map.get(presence_state, :note)
    basic = if status == :open, do: "open", else: "closed"

    note_element = if note, do: "<note>#{escape_xml(note)}</note>", else: ""

    """
    <?xml version="1.0" encoding="UTF-8"?>
    <presence xmlns="urn:ietf:params:xml:ns:pidf"
              entity="sip:#{username}@#{domain}">
      <tuple id="tuple1">
        <status>
          <basic>#{basic}</basic>
        </status>
        #{note_element}
      </tuple>
    </presence>
    """
  end

  defp build_pidf(_, _, nil), do: ""

  defp escape_xml(text) when is_binary(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&apos;")
  end

  defp escape_xml(nil), do: ""

  defp extract_etag(%{etag: etag}) when is_binary(etag), do: etag

  defp extract_etag(%{headers: headers}) do
    headers["SIP-ETag"] || headers["sip-etag"]
  end

  defp extract_etag(_), do: nil

  defp extract_expires(%{expires: expires}) when is_integer(expires), do: expires

  defp extract_expires(%{headers: headers}) do
    case headers["Expires"] do
      nil -> 3600
      expires when is_binary(expires) -> String.to_integer(expires)
      expires when is_integer(expires) -> expires
    end
  end

  defp extract_expires(_), do: 3600

  defp schedule_refresh(state, expires) do
    state = cancel_refresh(state)
    delay = max((expires - @refresh_buffer_seconds) * 1000, 30_000)
    timer = Process.send_after(self(), :refresh, delay)
    %{state | refresh_timer: timer, refresh_scheduled: true}
  end

  defp cancel_refresh(%{refresh_timer: nil} = state) do
    %{state | refresh_scheduled: false}
  end

  defp cancel_refresh(%{refresh_timer: timer} = state) do
    Process.cancel_timer(timer)
    %{state | refresh_timer: nil, refresh_scheduled: false}
  end

  defp notify_handler(event, info, state) do
    if state.notify_pid do
      send(state.notify_pid, {:presence_event, event, info})
    end
  end
end
