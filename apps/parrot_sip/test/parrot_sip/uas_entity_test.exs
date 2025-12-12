defmodule ParrotSip.UASEntityTest do
  use ExUnit.Case, async: true

  alias ParrotSip.{UAS, Message}

  setup do
    invite = %Message{
      type: :request,
      method: :invite,
      call_id: "test-call-#{System.unique_integer([:positive])}",
      from: %{uri: "sip:alice@example.com", parameters: %{"tag" => "alice-tag"}},
      to: %{uri: "sip:bob@example.com", parameters: %{}},
      cseq: %{number: 1, method: :invite},
      body: "v=0\r\no=- 123 456 IN IP4 192.168.1.1\r\n"
    }

    test_pid = self()
    notify_fun = fn event, _owner -> send(test_pid, {:uas_event, event}) end

    %{invite: invite, notify_fun: notify_fun, test_pid: test_pid}
  end

  describe "UAS happy path" do
    test "incoming -> ringing -> answering -> established", %{invite: invite, notify_fun: notify_fun} do
      {:ok, uas} = UAS.start_link(
        invite: invite,
        owner: self(),
        notify_fun: notify_fun,
        uas: :test_uas_ref
      )

      assert_receive {:uas_event, {:uas_created, ^uas}}

      :ok = UAS.ring(uas)
      assert_receive {:uas_event, {:uas_ringing, ^uas}}

      :ok = UAS.answer(uas, sdp: "v=0\r\no=- 789 012 IN IP4 192.168.1.2\r\n")
      assert_receive {:uas_event, {:uas_answered, ^uas}}

      send(uas, {:dialog_event, :ack_received})
      assert_receive {:uas_event, {:uas_established, ^uas}}
    end

    test "incoming -> answering (direct answer)", %{invite: invite, notify_fun: notify_fun} do
      {:ok, uas} = UAS.start_link(
        invite: invite,
        owner: self(),
        notify_fun: notify_fun,
        uas: :test_uas_ref
      )

      assert_receive {:uas_event, {:uas_created, ^uas}}

      :ok = UAS.answer(uas, sdp: "v=0\r\n")
      assert_receive {:uas_event, {:uas_answered, ^uas}}

      send(uas, {:dialog_event, :ack_received})
      assert_receive {:uas_event, {:uas_established, ^uas}}
    end
  end

  describe "UAS rejection" do
    test "reject with 486 Busy", %{invite: invite, notify_fun: notify_fun} do
      {:ok, uas} = UAS.start_link(
        invite: invite,
        owner: self(),
        notify_fun: notify_fun,
        uas: :test_uas_ref
      )

      assert_receive {:uas_event, {:uas_created, ^uas}}

      :ok = UAS.reject(uas, 486)
      assert_receive {:uas_event, {:uas_terminated, ^uas}}
    end

    test "reject after ringing", %{invite: invite, notify_fun: notify_fun} do
      {:ok, uas} = UAS.start_link(
        invite: invite,
        owner: self(),
        notify_fun: notify_fun,
        uas: :test_uas_ref
      )

      assert_receive {:uas_event, {:uas_created, ^uas}}

      :ok = UAS.ring(uas)
      assert_receive {:uas_event, {:uas_ringing, ^uas}}

      :ok = UAS.reject(uas, 480)
      assert_receive {:uas_event, {:uas_terminated, ^uas}}
    end
  end

  describe "UAS CANCEL handling" do
    test "CANCEL in incoming state", %{invite: invite, notify_fun: notify_fun} do
      {:ok, uas} = UAS.start_link(
        invite: invite,
        owner: self(),
        notify_fun: notify_fun,
        uas: :test_uas_ref
      )

      assert_receive {:uas_event, {:uas_created, ^uas}}

      :gen_statem.cast(uas, :cancel_received)
      assert_receive {:uas_event, {:uas_cancelled, ^uas}}
    end

    test "CANCEL in ringing state", %{invite: invite, notify_fun: notify_fun} do
      {:ok, uas} = UAS.start_link(
        invite: invite,
        owner: self(),
        notify_fun: notify_fun,
        uas: :test_uas_ref
      )

      assert_receive {:uas_event, {:uas_created, ^uas}}

      :ok = UAS.ring(uas)
      assert_receive {:uas_event, {:uas_ringing, ^uas}}

      :gen_statem.cast(uas, :cancel_received)
      assert_receive {:uas_event, {:uas_cancelled, ^uas}}
    end
  end

  describe "UAS Timer H timeout" do
    test "timeout if no ACK received", %{invite: invite, notify_fun: notify_fun} do
      {:ok, uas} = UAS.start_link(
        invite: invite,
        owner: self(),
        notify_fun: notify_fun,
        uas: :test_uas_ref
      )

      assert_receive {:uas_event, {:uas_created, ^uas}}

      :ok = UAS.answer(uas, sdp: "v=0\r\n")
      assert_receive {:uas_event, {:uas_answered, ^uas}}

      send(uas, {:dialog_event, :timer_h_timeout})
      assert_receive {:uas_event, {:uas_timeout, ^uas}}
    end
  end

  describe "UAS BYE handling" do
    test "receive BYE in established state", %{invite: invite, notify_fun: notify_fun} do
      {:ok, uas} = UAS.start_link(
        invite: invite,
        owner: self(),
        notify_fun: notify_fun,
        uas: :test_uas_ref
      )

      assert_receive {:uas_event, {:uas_created, ^uas}}

      :ok = UAS.answer(uas, sdp: "v=0\r\n")
      assert_receive {:uas_event, {:uas_answered, ^uas}}

      send(uas, {:dialog_event, :ack_received})
      assert_receive {:uas_event, {:uas_established, ^uas}}

      bye_msg = %Message{
        type: :request,
        method: :bye,
        call_id: invite.call_id
      }

      send(uas, {:dialog_event, {:bye_received, bye_msg}})
      assert_receive {:uas_event, {:uas_bye, ^uas, ^bye_msg}}
    end

    test "send BYE (hangup)", %{invite: invite, notify_fun: notify_fun} do
      {:ok, uas} = UAS.start_link(
        invite: invite,
        owner: self(),
        notify_fun: notify_fun,
        uas: :test_uas_ref
      )

      assert_receive {:uas_event, {:uas_created, ^uas}}

      :ok = UAS.answer(uas, sdp: "v=0\r\n")
      send(uas, {:dialog_event, :ack_received})
      assert_receive {:uas_event, {:uas_established, ^uas}}

      :ok = UAS.hangup(uas)
    end
  end

  describe "UAS Dialog discovery" do
    test "discovers dialog after answering", %{invite: invite, notify_fun: notify_fun} do
      dialog_id = "dialog:uas:#{invite.call_id}:test-local:#{invite.from.parameters["tag"]}"

      {:ok, _} = Registry.register(ParrotSip.Registry, dialog_id, %{})

      {:ok, uas} = UAS.start_link(
        invite: invite,
        owner: self(),
        notify_fun: notify_fun,
        uas: :test_uas_ref
      )

      assert_receive {:uas_event, {:uas_created, ^uas}}

      :ok = UAS.answer(uas, sdp: "v=0\r\n")
      assert_receive {:uas_event, {:uas_answered, ^uas}}

      Registry.unregister(ParrotSip.Registry, dialog_id)
    end
  end
end
