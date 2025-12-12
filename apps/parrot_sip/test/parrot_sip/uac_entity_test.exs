defmodule ParrotSip.UACEntityTest do
  use ExUnit.Case, async: true

  alias ParrotSip.{UAC, Message}

  setup do
    test_pid = self()
    notify_fun = fn event, _owner -> send(test_pid, {:uac_event, event}) end

    %{notify_fun: notify_fun, test_pid: test_pid}
  end

  describe "UAC happy path" do
    test "initiating -> calling -> ringing -> answered -> established", %{notify_fun: notify_fun} do
      {:ok, uac} = UAC.start_link(
        dest_uri: "sip:bob@example.com",
        sdp: "v=0\r\no=- 123 456 IN IP4 192.168.1.1\r\n",
        owner: self(),
        notify_fun: notify_fun
      )

      assert_receive {:uac_event, {:uac_created, ^uac}}

      send(uac, {:tx_response, {:response, %Message{status_code: 180, to: %{parameters: %{"tag" => "bob-tag"}}}}})
      assert_receive {:uac_event, {:uac_ringing, ^uac, 180, _resp}}

      send(uac, {:tx_response, {:response, %Message{status_code: 200, to: %{parameters: %{"tag" => "bob-tag"}}, body: "v=0\r\n"}}})
      assert_receive {:uac_event, {:uac_answered, ^uac, "v=0\r\n"}}

      # Mock dialog for unit testing
      mock_dialog = spawn(fn -> Process.sleep(:infinity) end)
      send(uac, {:test_dialog_found, mock_dialog})

      assert_receive {:uac_event, {:uac_established, ^uac}}, 1000
    end

    test "initiating -> calling -> answered (no ringing)", %{notify_fun: notify_fun} do
      {:ok, uac} = UAC.start_link(
        dest_uri: "sip:bob@example.com",
        sdp: "v=0\r\n",
        owner: self(),
        notify_fun: notify_fun
      )

      assert_receive {:uac_event, {:uac_created, ^uac}}

      send(uac, {:tx_response, {:response, %Message{status_code: 200, to: %{parameters: %{"tag" => "bob-tag"}}, body: "v=0\r\n"}}})
      assert_receive {:uac_event, {:uac_answered, ^uac, "v=0\r\n"}}

      # Mock dialog for unit testing
      mock_dialog = spawn(fn -> Process.sleep(:infinity) end)
      send(uac, {:test_dialog_found, mock_dialog})

      assert_receive {:uac_event, {:uac_established, ^uac}}, 1000
    end
  end

  describe "UAC rejection" do
    test "call rejected with 486 Busy", %{notify_fun: notify_fun} do
      {:ok, uac} = UAC.start_link(
        dest_uri: "sip:bob@example.com",
        sdp: "v=0\r\n",
        owner: self(),
        notify_fun: notify_fun
      )

      assert_receive {:uac_event, {:uac_created, ^uac}}

      send(uac, {:tx_response, {:response, %Message{status_code: 486, to: %{parameters: %{}}}}})
      assert_receive {:uac_event, {:uac_rejected, ^uac, 486, _resp}}
    end

    test "call rejected after ringing", %{notify_fun: notify_fun} do
      {:ok, uac} = UAC.start_link(
        dest_uri: "sip:bob@example.com",
        sdp: "v=0\r\n",
        owner: self(),
        notify_fun: notify_fun
      )

      assert_receive {:uac_event, {:uac_created, ^uac}}

      send(uac, {:tx_response, {:response, %Message{status_code: 180, to: %{parameters: %{"tag" => "bob-tag"}}}}})
      assert_receive {:uac_event, {:uac_ringing, ^uac, 180, _resp}}

      send(uac, {:tx_response, {:response, %Message{status_code: 480, to: %{parameters: %{"tag" => "bob-tag"}}}}})
      assert_receive {:uac_event, {:uac_rejected, ^uac, 480, _resp}}
    end
  end

  describe "UAC CANCEL" do
    test "cancel in calling state", %{notify_fun: notify_fun} do
      {:ok, uac} = UAC.start_link(
        dest_uri: "sip:bob@example.com",
        sdp: "v=0\r\n",
        owner: self(),
        notify_fun: notify_fun
      )

      assert_receive {:uac_event, {:uac_created, ^uac}}

      :ok = UAC.cancel(uac)
    end

    test "cancel in ringing state", %{notify_fun: notify_fun} do
      {:ok, uac} = UAC.start_link(
        dest_uri: "sip:bob@example.com",
        sdp: "v=0\r\n",
        owner: self(),
        notify_fun: notify_fun
      )

      assert_receive {:uac_event, {:uac_created, ^uac}}

      send(uac, {:tx_response, {:response, %Message{status_code: 180, to: %{parameters: %{"tag" => "bob-tag"}}}}})
      assert_receive {:uac_event, {:uac_ringing, ^uac, 180, _resp}}

      :ok = UAC.cancel(uac)
    end
  end

  describe "UAC BYE handling" do
    test "receive BYE in established state", %{notify_fun: notify_fun} do
      {:ok, uac} = UAC.start_link(
        dest_uri: "sip:bob@example.com",
        sdp: "v=0\r\n",
        owner: self(),
        notify_fun: notify_fun
      )

      assert_receive {:uac_event, {:uac_created, ^uac}}

      send(uac, {:tx_response, {:response, %Message{status_code: 200, to: %{parameters: %{"tag" => "bob-tag"}}, body: "v=0\r\n"}}})
      assert_receive {:uac_event, {:uac_answered, ^uac, "v=0\r\n"}}

      # Mock dialog for unit testing
      mock_dialog = spawn(fn -> Process.sleep(:infinity) end)
      send(uac, {:test_dialog_found, mock_dialog})

      assert_receive {:uac_event, {:uac_established, ^uac}}, 1000

      bye_msg = %Message{
        type: :request,
        method: :bye,
        call_id: "test-call-123"
      }

      send(uac, {:dialog_event, {:bye_received, bye_msg}})
      assert_receive {:uac_event, {:uac_bye, ^uac, ^bye_msg}}
    end

    test "send BYE (hangup)", %{notify_fun: notify_fun} do
      {:ok, uac} = UAC.start_link(
        dest_uri: "sip:bob@example.com",
        sdp: "v=0\r\n",
        owner: self(),
        notify_fun: notify_fun
      )

      assert_receive {:uac_event, {:uac_created, ^uac}}

      send(uac, {:tx_response, {:response, %Message{status_code: 200, to: %{parameters: %{"tag" => "bob-tag"}}, body: "v=0\r\n"}}})
      assert_receive {:uac_event, {:uac_answered, ^uac, "v=0\r\n"}}

      # Mock dialog for unit testing
      mock_dialog = spawn(fn -> Process.sleep(:infinity) end)
      send(uac, {:test_dialog_found, mock_dialog})

      assert_receive {:uac_event, {:uac_established, ^uac}}, 1000

      :ok = UAC.hangup(uac)
    end
  end

  describe "UAC Timer B timeout" do
    test "timeout if no response received - (skipped for speed)", %{notify_fun: notify_fun} do
      {:ok, _uac} = UAC.start_link(
        dest_uri: "sip:bob@example.com",
        sdp: "v=0\r\n",
        owner: self(),
        notify_fun: notify_fun
      )

      # Timer B is 32 seconds - too slow for unit tests
      # In production: assert_receive {:uac_event, {:uac_timeout, ^uac}}, 33_000
    end
  end

  describe "UAC progress responses" do
    test "multiple 18x responses", %{notify_fun: notify_fun} do
      {:ok, uac} = UAC.start_link(
        dest_uri: "sip:bob@example.com",
        sdp: "v=0\r\n",
        owner: self(),
        notify_fun: notify_fun
      )

      assert_receive {:uac_event, {:uac_created, ^uac}}

      send(uac, {:tx_response, {:response, %Message{status_code: 180, to: %{parameters: %{"tag" => "bob-tag"}}}}})
      assert_receive {:uac_event, {:uac_ringing, ^uac, 180, _resp}}

      send(uac, {:tx_response, {:response, %Message{status_code: 183, to: %{parameters: %{"tag" => "bob-tag"}}}}})
      assert_receive {:uac_event, {:uac_progress, ^uac, 183, _resp}}

      send(uac, {:tx_response, {:response, %Message{status_code: 200, to: %{parameters: %{"tag" => "bob-tag"}}, body: "v=0\r\n"}}})
      assert_receive {:uac_event, {:uac_answered, ^uac, "v=0\r\n"}}
    end
  end
end
