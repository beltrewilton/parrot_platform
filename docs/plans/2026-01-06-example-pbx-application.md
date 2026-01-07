# Example Application: Mini PBX

**Date:** 2026-01-06
**Purpose:** Demonstrate the Parrot DSL with a complete, working example.

---

## Overview

A simple 3-person PBX with:

- **Extensions:** Alice (100), Bob (101), Carol (102)
- **Voicemail:** When unavailable
- **Auto-attendant:** IVR for inbound PSTN calls
- **Outbound dialing:** Dial 9 + number to reach PSTN
- **Presence:** On call → busy, registered → available, unregistered → offline
- **Carrier trunks:** 2 SIP trunks for PSTN connectivity
- **Storage:** Mnesia for registrations, subscriptions, voicemail metadata

---

## Project Structure

```
mini_pbx/
├── lib/
│   ├── mini_pbx/
│   │   ├── application.ex
│   │   ├── router.ex
│   │   ├── handlers/
│   │   │   ├── extensions_handler.ex
│   │   │   ├── outbound_handler.ex
│   │   │   ├── inbound_trunk_handler.ex
│   │   │   ├── voicemail_handler.ex
│   │   │   ├── registration_handler.ex
│   │   │   └── presence_handler.ex
│   │   └── storage/
│   │       ├── mnesia_setup.ex
│   │       ├── registrations.ex
│   │       ├── subscriptions.ex
│   │       ├── voicemail.ex
│   │       └── users.ex
│   └── mini_pbx.ex
├── priv/
│   └── sounds/
│       ├── welcome.wav
│       ├── main-menu.wav
│       ├── press-1-alice.wav
│       ├── press-2-bob.wav
│       ├── press-3-carol.wav
│       ├── press-0-ring-all.wav
│       ├── please-hold.wav
│       ├── user-busy.wav
│       ├── no-answer.wav
│       ├── leave-message.wav
│       ├── message-saved.wav
│       ├── goodbye.wav
│       └── invalid-option.wav
├── config/
│   └── config.exs
└── test/
    └── ...
```

---

## Configuration

```elixir
# config/config.exs
import Config

config :mini_pbx,
  extensions: %{
    "100" => %{name: "Alice", password: "alice123"},
    "101" => %{name: "Bob", password: "bob456"},
    "102" => %{name: "Carol", password: "carol789"}
  },
  trunks: [
    %{name: "trunk1", host: "10.0.0.1", username: "miniPBX", password: "trunk1pass"},
    %{name: "trunk2", host: "10.0.0.2", username: "miniPBX", password: "trunk2pass"}
  ],
  voicemail_dir: "/var/spool/mini_pbx/voicemail"
```

---

## Application Startup

```elixir
# lib/mini_pbx/application.ex
defmodule MiniPBX.Application do
  use Application

  def start(_type, _args) do
    children = [
      # Initialize Mnesia tables
      MiniPBX.Storage.MnesiaSetup,

      # Parrot SIP stack
      {Parrot,
        router: MiniPBX.Router,
        transports: [
          {:udp, port: 5060},
          {:tcp, port: 5060}
        ]}
    ]

    opts = [strategy: :one_for_one, name: MiniPBX.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
```

---

## Mnesia Storage

```elixir
# lib/mini_pbx/storage/mnesia_setup.ex
defmodule MiniPBX.Storage.MnesiaSetup do
  use GenServer

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def init(_) do
    # Create schema if needed
    :mnesia.create_schema([node()])
    :mnesia.start()

    # Registrations table
    :mnesia.create_table(:registrations, [
      attributes: [:aor, :contacts, :updated_at],
      disc_copies: [node()]
    ])

    # Presence subscriptions table
    :mnesia.create_table(:subscriptions, [
      attributes: [:id, :watcher, :presentity, :expires, :contact],
      disc_copies: [node()],
      index: [:presentity, :watcher]
    ])

    # Presence state table
    :mnesia.create_table(:presence_state, [
      attributes: [:user, :status, :note, :updated_at],
      disc_copies: [node()]
    ])

    # Voicemail table
    :mnesia.create_table(:voicemails, [
      attributes: [:id, :mailbox, :from, :filename, :duration, :timestamp, :read],
      disc_copies: [node()],
      index: [:mailbox]
    ])

    :mnesia.wait_for_tables([:registrations, :subscriptions, :presence_state, :voicemails], 5000)

    {:ok, %{}}
  end
end
```

```elixir
# lib/mini_pbx/storage/registrations.ex
defmodule MiniPBX.Storage.Registrations do
  def store(aor, contact, expires) do
    :mnesia.transaction(fn ->
      existing = case :mnesia.read(:registrations, aor) do
        [{:registrations, ^aor, contacts, _}] -> contacts
        [] -> []
      end

      # Update or add contact
      updated = existing
        |> Enum.reject(fn c -> c.uri == contact.uri end)
        |> Enum.concat([%{uri: contact.uri, expires: expires, binding: contact.binding}])

      :mnesia.write({:registrations, aor, updated, DateTime.utc_now()})
    end)
    :ok
  end

  def get(aor) do
    case :mnesia.dirty_read(:registrations, aor) do
      [{:registrations, ^aor, contacts, _}] ->
        # Filter expired
        now = DateTime.utc_now()
        Enum.filter(contacts, fn c -> DateTime.compare(c.expires, now) == :gt end)
      [] ->
        []
    end
  end

  def delete(aor, contact_uri) do
    :mnesia.transaction(fn ->
      case :mnesia.read(:registrations, aor) do
        [{:registrations, ^aor, contacts, _}] ->
          updated = Enum.reject(contacts, fn c -> c.uri == contact_uri end)
          :mnesia.write({:registrations, aor, updated, DateTime.utc_now()})
        [] ->
          :ok
      end
    end)
    :ok
  end
end
```

```elixir
# lib/mini_pbx/storage/subscriptions.ex
defmodule MiniPBX.Storage.Subscriptions do
  def store(subscription) do
    id = :crypto.strong_rand_bytes(16) |> Base.encode16()
    :mnesia.transaction(fn ->
      :mnesia.write({:subscriptions, id, subscription.watcher, subscription.presentity,
                     subscription.expires, subscription.contact})
    end)
    :ok
  end

  def get_for_presentity(presentity) do
    :mnesia.dirty_index_read(:subscriptions, presentity, :presentity)
    |> Enum.map(fn {:subscriptions, id, watcher, presentity, expires, contact} ->
      %{id: id, watcher: watcher, presentity: presentity, expires: expires, contact: contact}
    end)
    |> Enum.filter(fn sub -> DateTime.compare(sub.expires, DateTime.utc_now()) == :gt end)
  end

  def delete(id) do
    :mnesia.transaction(fn ->
      :mnesia.delete({:subscriptions, id})
    end)
    :ok
  end
end
```

```elixir
# lib/mini_pbx/storage/presence_state.ex
defmodule MiniPBX.Storage.PresenceState do
  def set(user, status, note \\ nil) do
    :mnesia.transaction(fn ->
      :mnesia.write({:presence_state, user, status, note, DateTime.utc_now()})
    end)
    :ok
  end

  def get(user) do
    case :mnesia.dirty_read(:presence_state, user) do
      [{:presence_state, ^user, status, note, _}] -> %{status: status, note: note}
      [] -> %{status: :unknown, note: nil}
    end
  end
end
```

```elixir
# lib/mini_pbx/storage/voicemail.ex
defmodule MiniPBX.Storage.Voicemail do
  @voicemail_dir Application.compile_env(:mini_pbx, :voicemail_dir, "/var/spool/mini_pbx/voicemail")

  def save(mailbox, from, filename, duration) do
    id = :crypto.strong_rand_bytes(16) |> Base.encode16()
    :mnesia.transaction(fn ->
      :mnesia.write({:voicemails, id, mailbox, from, filename, duration, DateTime.utc_now(), false})
    end)
    {:ok, id}
  end

  def list(mailbox) do
    :mnesia.dirty_index_read(:voicemails, mailbox, :mailbox)
    |> Enum.map(fn {:voicemails, id, _mailbox, from, filename, duration, timestamp, read} ->
      %{id: id, from: from, filename: filename, duration: duration, timestamp: timestamp, read: read}
    end)
    |> Enum.sort_by(& &1.timestamp, {:desc, DateTime})
  end

  def mark_read(id) do
    :mnesia.transaction(fn ->
      case :mnesia.read(:voicemails, id) do
        [{:voicemails, ^id, mailbox, from, filename, duration, timestamp, _read}] ->
          :mnesia.write({:voicemails, id, mailbox, from, filename, duration, timestamp, true})
        [] ->
          :ok
      end
    end)
    :ok
  end

  def filepath(mailbox, filename) do
    Path.join([@voicemail_dir, mailbox, filename])
  end
end
```

```elixir
# lib/mini_pbx/storage/users.ex
defmodule MiniPBX.Storage.Users do
  @extensions Application.compile_env(:mini_pbx, :extensions, %{})

  def authenticate(username, password) do
    case Map.get(@extensions, username) do
      %{password: ^password} -> :ok
      _ -> :error
    end
  end

  def exists?(extension) do
    Map.has_key?(@extensions, extension)
  end

  def get(extension) do
    Map.get(@extensions, extension)
  end

  def all_extensions do
    Map.keys(@extensions)
  end
end
```

---

## Router

```elixir
# lib/mini_pbx/router.ex
defmodule MiniPBX.Router do
  use Parrot.Router

  # Pipeline for authenticated internal users
  pipeline :internal do
    plug :verify_registration
  end

  # Pipeline for trunk traffic
  pipeline :from_trunk do
    plug :validate_trunk_ip
  end

  # Internal extensions (registered users)
  scope "/", from_ip: "192.168.0.0/16" do
    pipe_through :internal

    # Extension to extension: 1xx
    invite "1xx", MiniPBX.Handlers.ExtensionsHandler

    # Voicemail access: *97
    invite "*97", MiniPBX.Handlers.VoicemailHandler

    # Outbound: 9 + number
    invite "9~", MiniPBX.Handlers.OutboundHandler
  end

  # Inbound from carrier trunks
  scope "/", from_ip: ["10.0.0.1", "10.0.0.2"] do
    pipe_through :from_trunk

    invite "*", MiniPBX.Handlers.InboundTrunkHandler
  end

  # Catch-all: reject
  invite "*", MiniPBX.Handlers.RejectHandler

  # Registration and presence
  register MiniPBX.Handlers.RegistrationHandler
  presence MiniPBX.Handlers.PresenceHandler
end
```

---

## Extensions Handler (Internal Calls)

```elixir
# lib/mini_pbx/handlers/extensions_handler.ex
defmodule MiniPBX.Handlers.ExtensionsHandler do
  use Parrot.InviteHandler

  alias MiniPBX.Storage.{Registrations, Users, PresenceState}

  def handle_invite(%{to: to, from: from} = invite) do
    extension = extract_extension(to)
    caller_ext = extract_extension(from)

    case Users.exists?(extension) do
      true ->
        invite
        |> answer()
        |> assign(:extension, extension)
        |> assign(:caller, caller_ext)
        |> try_extension(extension)

      false ->
        invite |> reject(404)
    end
  end

  defp try_extension(call, extension) do
    case Registrations.get("sip:#{extension}@mini.pbx") do
      [] ->
        # Not registered, go to voicemail
        call |> play("no-answer.wav")

      contacts ->
        # Try to reach them
        destinations = Enum.map(contacts, fn c -> c.uri end)
        call
        |> play("please-hold.wav")
    end
  end

  def handle_play_complete("please-hold.wav", call) do
    contacts = Registrations.get("sip:#{call.assigns.extension}@mini.pbx")

    case contacts do
      [] ->
        call |> goto_voicemail()

      [single] ->
        call |> bridge(single.uri, timeout: 30_000)

      multiple ->
        destinations = Enum.map(multiple, fn c -> {c.uri, []} end)
        call |> fork(destinations, strategy: :first_answer, timeout: 30_000)
    end
  end

  def handle_play_complete("no-answer.wav", call) do
    call |> goto_voicemail()
  end

  def handle_play_complete("user-busy.wav", call) do
    call |> goto_voicemail()
  end

  def handle_play_complete("leave-message.wav", call) do
    filename = "#{call.assigns.caller}-#{System.system_time(:second)}.wav"
    filepath = MiniPBX.Storage.Voicemail.filepath(call.assigns.extension, filename)
    call
    |> assign(:recording_file, filename)
    |> record(filepath, max_duration: 120_000, terminators: ["#"])
  end

  def handle_play_complete("message-saved.wav", call) do
    call |> play("goodbye.wav")
  end

  def handle_play_complete("goodbye.wav", call) do
    call |> hangup()
  end

  # Bridge events
  def handle_bridge_complete(:answered, call) do
    Parrot.Presence.notify(call.assigns.extension, %{status: :busy, note: "On a call"})
    Parrot.Presence.notify(call.assigns.caller, %{status: :busy, note: "On a call"})
    {:noreply, call}
  end

  def handle_bridge_complete({:failed, :busy}, call) do
    call |> play("user-busy.wav")
  end

  def handle_bridge_complete({:failed, :no_answer}, call) do
    call |> play("no-answer.wav")
  end

  def handle_bridge_complete({:failed, _reason}, call) do
    call |> play("no-answer.wav")
  end

  # Fork events
  def handle_fork_complete({:answered, _winner}, call) do
    Parrot.Presence.notify(call.assigns.extension, %{status: :busy, note: "On a call"})
    Parrot.Presence.notify(call.assigns.caller, %{status: :busy, note: "On a call"})
    {:noreply, call}
  end

  def handle_fork_complete(:no_answer, call) do
    call |> play("no-answer.wav")
  end

  # Recording events
  def handle_record_complete(filepath, duration, call) do
    MiniPBX.Storage.Voicemail.save(
      call.assigns.extension,
      call.assigns.caller,
      call.assigns.recording_file,
      duration
    )
    call |> play("message-saved.wav")
  end

  # Hangup
  def handle_hangup(call) do
    if call.assigns[:caller] do
      Parrot.Presence.notify(call.assigns.caller, %{status: :available})
    end
    if call.assigns[:extension] do
      Parrot.Presence.notify(call.assigns.extension, %{status: :available})
    end
    {:noreply, call}
  end

  # Helpers
  defp goto_voicemail(call) do
    call
    |> assign(:voicemail_mode, true)
    |> play("leave-message.wav")
  end

  defp extract_extension("sip:" <> rest) do
    rest |> String.split("@") |> List.first()
  end
  defp extract_extension(uri), do: uri
end
```

---

## Inbound Trunk Handler (Auto-Attendant)

```elixir
# lib/mini_pbx/handlers/inbound_trunk_handler.ex
defmodule MiniPBX.Handlers.InboundTrunkHandler do
  use Parrot.InviteHandler

  alias MiniPBX.Storage.Registrations

  def handle_invite(invite) do
    invite
    |> answer()
    |> assign(:menu, :main)
    |> assign(:retries, 0)
    |> play("welcome.wav")
  end

  def handle_play_complete("welcome.wav", call) do
    call |> play_main_menu()
  end

  def handle_play_complete("invalid-option.wav", call) do
    if call.assigns.retries < 3 do
      call |> play_main_menu()
    else
      call |> play("goodbye.wav")
    end
  end

  def handle_play_complete("goodbye.wav", call) do
    call |> hangup()
  end

  def handle_play_complete("please-hold.wav", call) do
    case call.assigns.target do
      :ring_all ->
        ring_all_extensions(call)

      extension ->
        contacts = Registrations.get("sip:#{extension}@mini.pbx")
        case contacts do
          [] -> call |> play("no-answer.wav")
          [single] -> call |> bridge(single.uri, timeout: 30_000)
          multiple ->
            destinations = Enum.map(multiple, fn c -> {c.uri, []} end)
            call |> fork(destinations, strategy: :first_answer, timeout: 30_000)
        end
    end
  end

  def handle_play_complete("no-answer.wav", call) do
    call |> play("goodbye.wav")
  end

  defp play_main_menu(call) do
    call |> play([
      "main-menu.wav",
      "press-1-alice.wav",
      "press-2-bob.wav",
      "press-3-carol.wav",
      "press-0-ring-all.wav"
    ])
  end

  # DTMF handling
  def handle_dtmf("1", %{assigns: %{menu: :main}} = call) do
    call
    |> assign(:target, "100")
    |> play("please-hold.wav")
  end

  def handle_dtmf("2", %{assigns: %{menu: :main}} = call) do
    call
    |> assign(:target, "101")
    |> play("please-hold.wav")
  end

  def handle_dtmf("3", %{assigns: %{menu: :main}} = call) do
    call
    |> assign(:target, "102")
    |> play("please-hold.wav")
  end

  def handle_dtmf("0", %{assigns: %{menu: :main}} = call) do
    call
    |> assign(:target, :ring_all)
    |> play("please-hold.wav")
  end

  def handle_dtmf(_, %{assigns: %{menu: :main}} = call) do
    call
    |> assign(:retries, call.assigns.retries + 1)
    |> play("invalid-option.wav")
  end

  def handle_dtmf(:timeout, call) do
    call |> play("goodbye.wav")
  end

  # Bridge/Fork events
  def handle_bridge_complete(:answered, call) do
    {:noreply, call}
  end

  def handle_bridge_complete({:failed, _reason}, call) do
    call |> play("no-answer.wav")
  end

  def handle_fork_complete({:answered, _winner}, call) do
    {:noreply, call}
  end

  def handle_fork_complete(:no_answer, call) do
    call |> play("no-answer.wav")
  end

  # Helpers
  defp ring_all_extensions(call) do
    all_contacts =
      MiniPBX.Storage.Users.all_extensions()
      |> Enum.flat_map(fn ext ->
        Registrations.get("sip:#{ext}@mini.pbx")
      end)

    case all_contacts do
      [] ->
        call |> play("no-answer.wav")

      contacts ->
        destinations = Enum.map(contacts, fn c -> {c.uri, []} end)
        call |> fork(destinations, strategy: :first_answer, timeout: 45_000)
    end
  end
end
```

---

## Outbound Handler (PSTN Calls)

```elixir
# lib/mini_pbx/handlers/outbound_handler.ex
defmodule MiniPBX.Handlers.OutboundHandler do
  use Parrot.InviteHandler

  @trunks Application.compile_env(:mini_pbx, :trunks, [])

  def handle_invite(%{to: to, from: from} = invite) do
    # Extract number after "9"
    number = extract_dialed_number(to)
    caller_ext = extract_extension(from)

    invite
    |> answer()
    |> assign(:number, number)
    |> assign(:caller, caller_ext)
    |> assign(:trunk_index, 0)
    |> play("please-hold.wav")
  end

  def handle_play_complete("please-hold.wav", call) do
    try_trunk(call, call.assigns.trunk_index)
  end

  def handle_play_complete("no-answer.wav", call) do
    call |> play("goodbye.wav")
  end

  def handle_play_complete("goodbye.wav", call) do
    call |> hangup()
  end

  defp try_trunk(call, index) when index >= length(@trunks) do
    # All trunks failed
    call |> play("no-answer.wav")
  end

  defp try_trunk(call, index) do
    trunk = Enum.at(@trunks, index)
    dest = "sip:#{call.assigns.number}@#{trunk.host}"

    call
    |> assign(:current_trunk, trunk.name)
    |> bridge(dest,
        timeout: 60_000,
        headers: %{
          "X-Trunk" => trunk.name,
          "X-Original-Caller" => call.assigns.caller
        })
  end

  # Bridge events
  def handle_bridge_complete(:answered, call) do
    Parrot.Presence.notify(call.assigns.caller, %{status: :busy, note: "On external call"})
    {:noreply, call}
  end

  def handle_bridge_complete({:failed, _reason}, call) do
    # Try next trunk
    next_index = call.assigns.trunk_index + 1
    call
    |> assign(:trunk_index, next_index)
    |> try_trunk(next_index)
  end

  def handle_hangup(call) do
    Parrot.Presence.notify(call.assigns.caller, %{status: :available})
    {:noreply, call}
  end

  # Helpers
  defp extract_dialed_number("sip:9" <> rest) do
    rest |> String.split("@") |> List.first()
  end

  defp extract_extension("sip:" <> rest) do
    rest |> String.split("@") |> List.first()
  end
  defp extract_extension(uri), do: uri
end
```

---

## Voicemail Handler

```elixir
# lib/mini_pbx/handlers/voicemail_handler.ex
defmodule MiniPBX.Handlers.VoicemailHandler do
  use Parrot.InviteHandler

  alias MiniPBX.Storage.Voicemail

  def handle_invite(%{from: from} = invite) do
    extension = extract_extension(from)

    invite
    |> answer()
    |> assign(:mailbox, extension)
    |> assign(:messages, Voicemail.list(extension))
    |> assign(:current_index, 0)
    |> play("welcome-voicemail.wav")
  end

  def handle_play_complete("welcome-voicemail.wav", call) do
    play_message_count(call)
  end

  defp play_message_count(call) do
    count = length(call.assigns.messages)
    # For simplicity, just announce and play first message
    # Real implementation would have number prompts
    if count > 0 do
      call |> play_current_message()
    else
      call |> play("no-messages.wav")
    end
  end

  defp play_current_message(call) do
    message = Enum.at(call.assigns.messages, call.assigns.current_index)
    if message do
      filepath = Voicemail.filepath(call.assigns.mailbox, message.filename)
      call |> play(filepath)
    else
      call |> play("end-of-messages.wav")
    end
  end

  def handle_play_complete("no-messages.wav", call) do
    call |> play("goodbye.wav")
  end

  def handle_play_complete("end-of-messages.wav", call) do
    call |> play("goodbye.wav")
  end

  def handle_play_complete("goodbye.wav", call) do
    call |> hangup()
  end

  def handle_play_complete(_filename, call) do
    # After playing a voicemail, mark as read and wait for input
    message = Enum.at(call.assigns.messages, call.assigns.current_index)
    if message, do: Voicemail.mark_read(message.id)

    call |> collect_dtmf(max: 1, timeout: 5_000)
  end

  # DTMF: 3 = delete, 6 = next, 4 = previous, * = exit
  def handle_dtmf("6", call) do
    # Next message
    call
    |> assign(:current_index, call.assigns.current_index + 1)
    |> play_current_message()
  end

  def handle_dtmf("4", call) do
    # Previous message
    new_index = max(0, call.assigns.current_index - 1)
    call
    |> assign(:current_index, new_index)
    |> play_current_message()
  end

  def handle_dtmf("3", call) do
    # Delete current message (would implement delete)
    call
    |> assign(:current_index, call.assigns.current_index + 1)
    |> play_current_message()
  end

  def handle_dtmf("*", call) do
    call |> play("goodbye.wav")
  end

  def handle_dtmf(:timeout, call) do
    call |> play("goodbye.wav")
  end

  def handle_dtmf(_, call) do
    # Replay current
    call |> play_current_message()
  end

  defp extract_extension("sip:" <> rest) do
    rest |> String.split("@") |> List.first()
  end
  defp extract_extension(uri), do: uri
end
```

---

## Registration Handler

```elixir
# lib/mini_pbx/handlers/registration_handler.ex
defmodule MiniPBX.Handlers.RegistrationHandler do
  use Parrot.RegistrationHandler

  alias MiniPBX.Storage.{Registrations, Users}

  def authenticate(credentials) do
    Users.authenticate(credentials.username, credentials.password)
  end

  def store_binding(aor, contact, expires) do
    Registrations.store(aor, contact, expires)

    # Update presence to available
    extension = extract_extension(aor)
    Parrot.Presence.notify(extension, %{status: :available, note: "Online"})

    :ok
  end

  def get_bindings(aor) do
    Registrations.get(aor)
  end

  def handle_registration_expired(aor) do
    extension = extract_extension(aor)
    Parrot.Presence.notify(extension, %{status: :offline, note: "Offline"})
    :ok
  end

  defp extract_extension("sip:" <> rest) do
    rest |> String.split("@") |> List.first()
  end
  defp extract_extension(uri), do: uri
end
```

---

## Presence Handler

```elixir
# lib/mini_pbx/handlers/presence_handler.ex
defmodule MiniPBX.Handlers.PresenceHandler do
  use Parrot.PresenceHandler

  alias MiniPBX.Storage.{Subscriptions, PresenceState, Users}

  def authorize_subscription(watcher, presentity) do
    # Allow all internal users to watch each other
    watcher_ext = extract_extension(watcher)
    presentity_ext = extract_extension(presentity)

    if Users.exists?(watcher_ext) and Users.exists?(presentity_ext) do
      :allow
    else
      :deny
    end
  end

  def store_subscription(subscription) do
    Subscriptions.store(subscription)
  end

  def get_subscriptions(presentity) do
    presentity_ext = extract_extension(presentity)
    Subscriptions.get_for_presentity(presentity_ext)
  end

  def get_presence(presentity) do
    presentity_ext = extract_extension(presentity)
    state = PresenceState.get(presentity_ext)

    case state.status do
      :available -> %{status: :open, note: state.note || "Available"}
      :busy -> %{status: :closed, note: state.note || "Busy"}
      :offline -> %{status: :closed, note: "Offline"}
      _ -> %{status: :closed, note: "Unknown"}
    end
  end

  def handle_publish(presentity, presence_state) do
    presentity_ext = extract_extension(presentity)
    PresenceState.set(presentity_ext, presence_state.status, presence_state[:note])
    :ok
  end

  defp extract_extension("sip:" <> rest) do
    rest |> String.split("@") |> List.first()
  end
  defp extract_extension(uri), do: uri
end
```

---

## Reject Handler

```elixir
# lib/mini_pbx/handlers/reject_handler.ex
defmodule MiniPBX.Handlers.RejectHandler do
  use Parrot.InviteHandler

  def handle_invite(invite) do
    invite |> reject(403)
  end
end
```

---

## Summary

This example demonstrates:

| Feature | Implementation |
|---------|----------------|
| **Extension calls** | Pattern match on `1xx`, lookup registration, bridge or fork |
| **Voicemail** | Record when unavailable, play back via `*97` |
| **Auto-attendant** | IVR menu for inbound PSTN, DTMF navigation |
| **Ring all** | Fork to all registered contacts |
| **Outbound PSTN** | Dial `9+number`, try trunks with failover |
| **Presence** | Update on register/unregister, call start/end |
| **Storage** | Mnesia for registrations, subscriptions, voicemail |

All using the Parrot DSL patterns:
- Pipeline builder (`|>`)
- Defined callbacks (`handle_play_complete`, `handle_dtmf`, etc.)
- Framework-handled registration/presence with user callbacks
- `call.assigns` for state
- Sensible defaults with selective override
