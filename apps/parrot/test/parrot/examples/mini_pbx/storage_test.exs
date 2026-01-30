defmodule Parrot.Examples.MiniPBX.StorageTest do
  @moduledoc """
  Tests for the Mini PBX Mnesia-based Storage module.

  Tests registration storage, voicemail storage, and call logs.
  """
  use ExUnit.Case, async: false

  alias Parrot.Examples.MiniPBX.Storage

  # Start storage once for all tests, clear between tests
  setup_all do
    # Ensure Mnesia is started
    :mnesia.start()

    # Start the storage GenServer if not already running
    case Storage.start_link() do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
    end

    :ok
  end

  setup do
    # Clear all tables between tests for isolation
    Storage.clear_all()
    :ok
  end

  describe "registration storage" do
    test "stores and retrieves registration" do
      aor = "sip:1001@pbx.local"
      contact = "sip:1001@192.168.1.100:5060"
      expires = 3600

      :ok = Storage.register(aor, contact, expires)

      assert {:ok, registrations} = Storage.get_registrations(aor)
      assert length(registrations) == 1

      [reg] = registrations
      assert reg.contact == contact
      assert reg.expires == expires
    end

    test "handles multiple contacts for same AOR" do
      aor = "sip:1001@pbx.local"

      :ok = Storage.register(aor, "sip:1001@192.168.1.100:5060", 3600)
      :ok = Storage.register(aor, "sip:1001@192.168.1.101:5060", 3600)

      {:ok, registrations} = Storage.get_registrations(aor)
      assert length(registrations) == 2
    end

    test "unregisters contact" do
      aor = "sip:1001@pbx.local"
      contact = "sip:1001@192.168.1.100:5060"

      :ok = Storage.register(aor, contact, 3600)
      :ok = Storage.unregister(aor, contact)

      {:ok, registrations} = Storage.get_registrations(aor)
      assert length(registrations) == 0
    end

    test "returns empty list for unknown AOR" do
      {:ok, registrations} = Storage.get_registrations("sip:unknown@pbx.local")
      assert registrations == []
    end
  end

  describe "extension lookup" do
    test "looks up extension by number" do
      # Register extension 1001
      aor = "sip:1001@pbx.local"
      contact = "sip:1001@192.168.1.100:5060"

      :ok = Storage.register(aor, contact, 3600)

      # Lookup by extension number
      assert {:ok, ^contact} = Storage.lookup_extension("1001")
    end

    test "returns error for unregistered extension" do
      assert {:error, :not_registered} = Storage.lookup_extension("9999")
    end
  end

  describe "voicemail storage" do
    test "stores and retrieves voicemail message" do
      extension = "1001"
      from = "sip:alice@example.com"
      file_path = "/var/spool/voicemail/1001/msg001.wav"

      :ok = Storage.store_voicemail(extension, from, file_path)

      {:ok, messages} = Storage.get_voicemails(extension)
      assert length(messages) == 1

      [msg] = messages
      assert msg.from == from
      assert msg.file_path == file_path
      assert msg.read == false
    end

    test "marks voicemail as read" do
      extension = "1001"
      :ok = Storage.store_voicemail(extension, "sip:bob@test.com", "/path/msg.wav")

      {:ok, [msg]} = Storage.get_voicemails(extension)
      :ok = Storage.mark_voicemail_read(extension, msg.id)

      {:ok, [updated_msg]} = Storage.get_voicemails(extension)
      assert updated_msg.read == true
    end

    test "deletes voicemail message" do
      extension = "1001"
      :ok = Storage.store_voicemail(extension, "sip:bob@test.com", "/path/msg.wav")

      {:ok, [msg]} = Storage.get_voicemails(extension)
      :ok = Storage.delete_voicemail(extension, msg.id)

      {:ok, messages} = Storage.get_voicemails(extension)
      assert messages == []
    end
  end
end
