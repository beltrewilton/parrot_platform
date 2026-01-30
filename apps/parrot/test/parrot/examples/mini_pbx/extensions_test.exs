defmodule Parrot.Examples.MiniPBX.ExtensionsTest do
  @moduledoc """
  Tests for the Mini PBX Extensions handler.

  Tests extension-to-extension calling with:
  - Registration lookup
  - Bridge to registered contact
  - No-answer to voicemail
  - Busy handling
  """
  use ExUnit.Case, async: false

  alias Parrot.Call
  alias Parrot.Examples.MiniPBX.{Extensions, Storage}

  # Start storage once for all tests
  setup_all do
    :mnesia.start()

    case Storage.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  setup do
    Storage.clear_all()
    :ok
  end

  describe "handle_invite/1" do
    test "bridges to registered extension" do
      # Register extension 1001
      aor = "sip:1001@pbx.local"
      contact = "sip:1001@192.168.1.100:5060"
      :ok = Storage.register(aor, contact, 3600)

      # Create incoming call to 1001
      call =
        Call.new(
          from: "sip:1002@pbx.local",
          to: "sip:1001@pbx.local",
          method: "INVITE"
        )

      # Handle the INVITE
      result = Extensions.handle_invite(call)

      # Should have answer and bridge operations queued
      operations = result.__operations__
      assert Enum.any?(operations, &match?({:answer, _}, &1))
      assert Enum.any?(operations, &match?({:bridge, _, _}, &1))

      # Verify bridge destination is the registered contact
      {:bridge, dest, _opts} = Enum.find(operations, &match?({:bridge, _, _}, &1))
      assert dest == contact

      # Should store the extension in assigns
      assert result.assigns[:extension] == "1001"
    end

    test "rejects with 404 for unregistered extension" do
      # Create call to unregistered extension
      call =
        Call.new(
          from: "sip:1002@pbx.local",
          to: "sip:1999@pbx.local",
          method: "INVITE"
        )

      result = Extensions.handle_invite(call)

      # Should have reject operation with 404
      operations = result.__operations__
      assert Enum.any?(operations, &match?({:reject, 404}, &1))
    end

    test "extracts extension number from To URI" do
      # Register extension 1050
      :ok = Storage.register("sip:1050@pbx.local", "sip:1050@10.0.0.50:5060", 3600)

      call =
        Call.new(
          from: "sip:1002@pbx.local",
          to: "sip:1050@pbx.local",
          method: "INVITE"
        )

      result = Extensions.handle_invite(call)

      # Should extract 1050 from the To URI
      assert result.assigns[:extension] == "1050"
    end

    test "stores caller info in assigns" do
      :ok = Storage.register("sip:1001@pbx.local", "sip:1001@192.168.1.100:5060", 3600)

      call =
        Call.new(
          from: "sip:1002@pbx.local",
          to: "sip:1001@pbx.local",
          method: "INVITE"
        )

      result = Extensions.handle_invite(call)

      # Should store caller in assigns
      assert result.assigns[:caller] == "sip:1002@pbx.local"
    end
  end

  describe "handle_bridge_complete/2" do
    test "handles answered bridge" do
      call =
        Call.new(
          from: "sip:1002@pbx.local",
          to: "sip:1001@pbx.local"
        )
        |> Call.assign(:extension, "1001")
        |> Call.assign(:caller, "sip:1002@pbx.local")

      result = Extensions.handle_bridge_complete(:answered, call)

      # Should return noreply (call continues normally)
      assert match?({:noreply, _}, result)
    end

    test "forwards to voicemail on no_answer" do
      call =
        Call.new(
          from: "sip:1002@pbx.local",
          to: "sip:1001@pbx.local"
        )
        |> Call.assign(:extension, "1001")
        |> Call.assign(:caller, "sip:1002@pbx.local")

      result = Extensions.handle_bridge_complete({:failed, :no_answer}, call)

      # Should flag for voicemail and play greeting
      # The result could be a Call struct or {:noreply, call}
      result_call = case result do
        {:noreply, c} -> c
        c -> c
      end

      assert result_call.assigns[:voicemail] == true
    end

    test "plays busy message on busy" do
      call =
        Call.new(
          from: "sip:1002@pbx.local",
          to: "sip:1001@pbx.local"
        )
        |> Call.assign(:extension, "1001")

      result = Extensions.handle_bridge_complete({:failed, :busy}, call)

      # Should have play and hangup operations
      result_call = case result do
        {:noreply, c} -> c
        c -> c
      end

      operations = result_call.__operations__
      assert Enum.any?(operations, &match?({:play, _, _}, &1))
      assert Enum.any?(operations, &match?({:hangup, _}, &1))
    end

    test "handles generic failure" do
      call =
        Call.new(
          from: "sip:1002@pbx.local",
          to: "sip:1001@pbx.local"
        )
        |> Call.assign(:extension, "1001")

      result = Extensions.handle_bridge_complete({:failed, :unavailable}, call)

      # Should play error and hangup
      result_call = case result do
        {:noreply, c} -> c
        c -> c
      end

      operations = result_call.__operations__
      assert Enum.any?(operations, fn
        {:play, _, _} -> true
        {:hangup, _} -> true
        _ -> false
      end)
    end
  end

  describe "handle_hangup/1" do
    test "returns noreply" do
      call =
        Call.new(
          from: "sip:1002@pbx.local",
          to: "sip:1001@pbx.local"
        )
        |> Call.assign(:extension, "1001")

      result = Extensions.handle_hangup(call)

      # Should return {:noreply, call}
      assert match?({:noreply, _}, result)
    end
  end
end
