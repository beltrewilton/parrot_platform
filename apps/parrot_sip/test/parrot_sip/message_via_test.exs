defmodule ParrotSip.MessageViaTest do
  use ExUnit.Case, async: true

  alias ParrotSip.Message
  alias ParrotSip.Headers.Via

  test "handles Via headers as struct fields" do
    # Via is now a struct field, not in headers map
    message = %Message{
      method: :invite,
      request_uri: "sip:bob@example.com",
      type: :request,
      dialog_id: "dlg-via",
      transaction_id: "txn-via",
      via: Via.parse("SIP/2.0/UDP client.atlanta.com:5060;branch=z9hG4bK74bf9")
    }

    assert message.dialog_id == "dlg-via"
    assert message.transaction_id == "txn-via"

    # Direct access to Via struct field
    assert is_struct(message.via, Via)
    assert message.via.host == "client.atlanta.com"
    assert message.via.port == 5060
    assert message.via.transport == :udp
    assert message.via.parameters["branch"] == "z9hG4bK74bf9"

    # Via as a list of structs
    message = %Message{
      method: :invite,
      request_uri: "sip:bob@example.com",
      type: :request,
      dialog_id: "dlg-via",
      transaction_id: "txn-via",
      via: [
        Via.parse("SIP/2.0/UDP client.atlanta.com:5060;branch=z9hG4bK74bf9"),
        Via.parse("SIP/2.0/TCP server.biloxi.com:5061;branch=z9hG4bK123")
      ]
    }

    assert message.dialog_id == "dlg-via"
    assert message.transaction_id == "txn-via"

    # Direct access to Via list
    assert is_list(message.via)
    assert length(message.via) == 2
    assert Enum.all?(message.via, &is_struct(&1, Via))

    # Pattern match to get first Via
    [first_via | rest] = message.via
    assert first_via.host == "client.atlanta.com"
    assert first_via.transport == :udp

    # Get second Via
    [second_via] = rest
    assert second_via.host == "server.biloxi.com"
    assert second_via.transport == :tcp
  end

  test "can modify Via headers with MessageHelper" do
    alias ParrotSip.MessageHelper

    message = %Message{
      method: :invite,
      request_uri: "sip:bob@example.com",
      type: :request,
      dialog_id: "dlg-via2",
      transaction_id: "txn-via2",
      via: Via.parse("SIP/2.0/UDP client.atlanta.com:5060;branch=z9hG4bK74bf9")
    }

    assert message.dialog_id == "dlg-via2"
    assert message.transaction_id == "txn-via2"

    # Add received parameter
    updated = MessageHelper.set_received_parameter(message, "192.168.1.1")
    
    # Via is directly accessible as struct field
    assert is_struct(updated.via, Via)
    assert updated.via.parameters["received"] == "192.168.1.1"

    # Convert back to string for assertion
    via_string = Via.format(updated.via)
    assert via_string =~ "received=192.168.1.1"

    # Add rport parameter
    with_rport = MessageHelper.set_rport_parameter(message, 12345)
    
    # Via is directly accessible as struct field
    assert is_struct(with_rport.via, Via)
    assert with_rport.via.parameters["rport"] == "12345"

    # Convert back to string for assertion
    rport_string = Via.format(with_rport.via)
    assert rport_string =~ "rport=12345"
  end
end
