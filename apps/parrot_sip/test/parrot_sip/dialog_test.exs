defmodule ParrotSip.DialogTest do
  use ExUnit.Case, async: true

  alias ParrotSip.Dialog
  alias ParrotSip.Message
  alias ParrotSip.Headers.{From, To, CSeq, Contact}
  alias ParrotSip.Uri

  describe "from_message/1" do
    test "extracts dialog ID from incoming request" do
      request = %Message{
        type: :request,
        method: :invite,
        direction: :incoming,
        from: %From{parameters: %{"tag" => "from-tag-123"}},
        to: %To{parameters: %{"tag" => "to-tag-456"}},
        call_id: "call-123@example.com",
        other_headers: %{}
      }

      dialog_id = Dialog.from_message(request)

      assert dialog_id.call_id == "call-123@example.com"
      assert dialog_id.local_tag == "from-tag-123"
      assert dialog_id.remote_tag == "to-tag-456"
      assert dialog_id.direction == :uas
    end

    test "extracts dialog ID from outgoing request" do
      request = %Message{
        type: :request,
        method: :bye,
        direction: :outgoing,
        from: %From{parameters: %{"tag" => "from-tag-123"}},
        to: %To{parameters: %{"tag" => "to-tag-456"}},
        call_id: "call-123@example.com",
        other_headers: %{}
      }

      dialog_id = Dialog.from_message(request)

      assert dialog_id.call_id == "call-123@example.com"
      assert dialog_id.local_tag == "from-tag-123"
      assert dialog_id.remote_tag == "to-tag-456"
      assert dialog_id.direction == :uac
    end

    test "extracts dialog ID from incoming response" do
      response = %Message{
        type: :response,
        status_code: 200,
        direction: :incoming,
        from: %From{parameters: %{"tag" => "from-tag-123"}},
        to: %To{parameters: %{"tag" => "to-tag-456"}},
        call_id: "call-123@example.com",
        other_headers: %{}
      }

      dialog_id = Dialog.from_message(response)

      # For responses, tags are swapped
      assert dialog_id.call_id == "call-123@example.com"
      assert dialog_id.local_tag == "to-tag-456"
      assert dialog_id.remote_tag == "from-tag-123"
      assert dialog_id.direction == :uas
    end

    test "handles missing To tag in initial request" do
      request = %Message{
        type: :request,
        method: :invite,
        direction: :incoming,
        from: %From{parameters: %{"tag" => "from-tag-123"}},
        to: %To{parameters: %{}},
        call_id: "call-123@example.com",
        other_headers: %{}
      }

      dialog_id = Dialog.from_message(request)

      assert dialog_id.call_id == "call-123@example.com"
      assert dialog_id.local_tag == "from-tag-123"
      assert dialog_id.remote_tag == nil
      assert dialog_id.direction == :uas
    end
  end

  describe "to_string/1" do
    test "generates consistent dialog ID string with complete tags" do
      dialog = %Dialog{
        call_id: "abc@example.com",
        local_tag: "tag-123",
        remote_tag: "tag-456"
      }

      result = Dialog.to_string(dialog)
      assert result == "abc@example.com;local=tag-123;remote=tag-456"
    end

    test "generates dialog ID string without remote tag" do
      dialog = %Dialog{
        call_id: "abc@example.com",
        local_tag: "tag-123",
        remote_tag: nil
      }

      result = Dialog.to_string(dialog)
      assert result == "abc@example.com;local=tag-123"
    end

    test "generates dialog ID string from map with direction" do
      dialog_id = %{
        call_id: "abc@example.com",
        local_tag: "tag-123",
        remote_tag: "tag-456",
        direction: :uac
      }

      result = Dialog.to_string(dialog_id)
      assert result == "abc@example.com;local=tag-123;remote=tag-456;uac"
    end

    test "generates dialog ID string from map without direction" do
      dialog_id = %{
        call_id: "abc@example.com",
        local_tag: "tag-123",
        remote_tag: nil
      }

      result = Dialog.to_string(dialog_id)
      assert result == "abc@example.com;local=tag-123"
    end
  end

  describe "is_complete?/1" do
    test "returns true for complete dialog ID" do
      dialog = %Dialog{
        local_tag: "tag-123",
        remote_tag: "tag-456"
      }

      assert Dialog.is_complete?(dialog)
    end

    test "returns false for dialog ID without remote tag" do
      dialog = %Dialog{
        local_tag: "tag-123",
        remote_tag: nil
      }

      refute Dialog.is_complete?(dialog)
    end

    test "returns false for dialog ID without local tag" do
      dialog = %Dialog{
        local_tag: nil,
        remote_tag: "tag-456"
      }

      refute Dialog.is_complete?(dialog)
    end

    test "works with map dialog ID" do
      dialog_id = %{
        local_tag: "tag-123",
        remote_tag: "tag-456"
      }

      assert Dialog.is_complete?(dialog_id)
    end
  end

  describe "new/4" do
    test "creates dialog ID with all parameters" do
      dialog_id = Dialog.new("call-123", "local-456", "remote-789", :uas)

      assert dialog_id.call_id == "call-123"
      assert dialog_id.local_tag == "local-456"
      assert dialog_id.remote_tag == "remote-789"
      assert dialog_id.direction == :uas
    end

    test "creates dialog ID with default direction" do
      dialog_id = Dialog.new("call-123", "local-456", "remote-789")

      assert dialog_id.direction == :uac
    end

    test "creates dialog ID without remote tag" do
      dialog_id = Dialog.new("call-123", "local-456")

      assert dialog_id.remote_tag == nil
      assert dialog_id.direction == :uac
    end
  end

  describe "peer_dialog_id/1" do
    test "swaps tags and direction for UAC" do
      dialog_id = %{
        call_id: "call-123",
        local_tag: "local-456",
        remote_tag: "remote-789",
        direction: :uac
      }

      peer = Dialog.peer_dialog_id(dialog_id)

      assert peer.call_id == "call-123"
      assert peer.local_tag == "remote-789"
      assert peer.remote_tag == "local-456"
      assert peer.direction == :uas
    end

    test "swaps tags and direction for UAS" do
      dialog_id = %{
        call_id: "call-123",
        local_tag: "local-456",
        remote_tag: "remote-789",
        direction: :uas
      }

      peer = Dialog.peer_dialog_id(dialog_id)

      assert peer.call_id == "call-123"
      assert peer.local_tag == "remote-789"
      assert peer.remote_tag == "local-456"
      assert peer.direction == :uac
    end
  end

  describe "match?/2" do
    test "returns true for identical dialog IDs" do
      dialog_id1 = %{
        call_id: "call-123",
        local_tag: "tag-456",
        remote_tag: "tag-789"
      }

      dialog_id2 = %{
        call_id: "call-123",
        local_tag: "tag-456",
        remote_tag: "tag-789"
      }

      assert Dialog.match?(dialog_id1, dialog_id2)
    end

    test "returns true for swapped tags (peer perspectives)" do
      dialog_id1 = %{
        call_id: "call-123",
        local_tag: "tag-456",
        remote_tag: "tag-789"
      }

      dialog_id2 = %{
        call_id: "call-123",
        local_tag: "tag-789",
        remote_tag: "tag-456"
      }

      assert Dialog.match?(dialog_id1, dialog_id2)
    end

    test "returns false for different call IDs" do
      dialog_id1 = %{
        call_id: "call-123",
        local_tag: "tag-456",
        remote_tag: "tag-789"
      }

      dialog_id2 = %{
        call_id: "call-999",
        local_tag: "tag-456",
        remote_tag: "tag-789"
      }

      refute Dialog.match?(dialog_id1, dialog_id2)
    end

    test "returns false for different tags" do
      dialog_id1 = %{
        call_id: "call-123",
        local_tag: "tag-456",
        remote_tag: "tag-789"
      }

      dialog_id2 = %{
        call_id: "call-123",
        local_tag: "tag-111",
        remote_tag: "tag-222"
      }

      refute Dialog.match?(dialog_id1, dialog_id2)
    end
  end

  describe "with_remote_tag/2" do
    test "updates dialog ID with remote tag" do
      dialog_id = %{
        call_id: "call-123",
        local_tag: "local-456",
        remote_tag: nil
      }

      updated = Dialog.with_remote_tag(dialog_id, "remote-789")

      assert updated.remote_tag == "remote-789"
      assert updated.call_id == "call-123"
      assert updated.local_tag == "local-456"
    end

    test "overwrites existing remote tag" do
      dialog_id = %{
        call_id: "call-123",
        local_tag: "local-456",
        remote_tag: "old-remote"
      }

      updated = Dialog.with_remote_tag(dialog_id, "new-remote")

      assert updated.remote_tag == "new-remote"
    end
  end

  describe "uas_create/2" do
    setup do
      request = %Message{
        method: :invite,
        request_uri: "sip:bob@example.com",
        from: %From{
          uri: Uri.parse!("sip:alice@example.com"),
          parameters: %{"tag" => "from-tag-123"}
        },
        to: %To{
          uri: Uri.parse!("sip:bob@example.com"),
          parameters: %{}
        },
        call_id: "call-123@example.com",
        cseq: %CSeq{number: 100, method: :invite},
        contact: %Contact{
          uri: Uri.parse!("sip:alice@192.168.1.100:5060")
        },
        other_headers: %{}
      }

      response = %Message{
        type: :response,
        status_code: 200,
        from: %From{
          uri: Uri.parse!("sip:alice@example.com"),
          parameters: %{"tag" => "from-tag-123"}
        },
        to: %To{
          uri: Uri.parse!("sip:bob@example.com"),
          parameters: %{"tag" => "to-tag-456"}
        },
        call_id: "call-123@example.com",
        cseq: %CSeq{number: 100, method: :invite},
        other_headers: %{}
      }

      {:ok, request: request, response: response}
    end

    test "creates dialog from UAS perspective", %{request: request, response: response} do
      {:ok, dialog} = Dialog.uas_create(request, response)

      assert dialog.call_id == "call-123@example.com"
      assert dialog.local_tag == "to-tag-456"
      assert dialog.remote_tag == "from-tag-123"
      assert dialog.local_uri == "sip:bob@example.com"
      assert dialog.remote_uri == "sip:alice@example.com"
      assert dialog.remote_target == "sip:alice@192.168.1.100:5060"
      assert dialog.remote_seq == 100
      assert dialog.local_seq == 0
      assert dialog.state == :confirmed
    end

    test "creates early dialog for provisional response", %{request: request} do
      provisional = %Message{
        type: :response,
        status_code: 180,
        from: %From{
          uri: Uri.parse!("sip:alice@example.com"),
          parameters: %{"tag" => "from-tag-123"}
        },
        to: %To{
          uri: Uri.parse!("sip:bob@example.com"),
          parameters: %{"tag" => "to-tag-456"}
        },
        call_id: "call-123@example.com",
        cseq: %CSeq{number: 100, method: :invite},
        other_headers: %{}
      }

      {:ok, dialog} = Dialog.uas_create(request, provisional)

      assert dialog.state == :early
    end
  end

  describe "uac_create/2" do
    setup do
      request = %Message{
        method: :invite,
        request_uri: "sip:bob@example.com",
        from: %From{
          uri: Uri.parse!("sip:alice@example.com"),
          parameters: %{"tag" => "from-tag-123"}
        },
        to: %To{
          uri: Uri.parse!("sip:bob@example.com"),
          parameters: %{}
        },
        call_id: "call-123@example.com",
        cseq: %CSeq{number: 100, method: :invite},
        other_headers: %{}
      }

      response = %Message{
        type: :response,
        status_code: 200,
        from: %From{
          uri: Uri.parse!("sip:alice@example.com"),
          parameters: %{"tag" => "from-tag-123"}
        },
        to: %To{
          uri: Uri.parse!("sip:bob@example.com"),
          parameters: %{"tag" => "to-tag-456"}
        },
        call_id: "call-123@example.com",
        cseq: %CSeq{number: 100, method: :invite},
        contact: %Contact{
          uri: Uri.parse!("sip:bob@192.168.1.200:5060")
        },
        other_headers: %{}
      }

      {:ok, request: request, response: response}
    end

    test "creates dialog from UAC perspective", %{request: request, response: response} do
      {:ok, dialog} = Dialog.uac_create(request, response)

      assert dialog.call_id == "call-123@example.com"
      assert dialog.local_tag == "from-tag-123"
      assert dialog.remote_tag == "to-tag-456"
      assert dialog.local_uri == "sip:alice@example.com"
      assert dialog.remote_uri == "sip:bob@example.com"
      assert dialog.remote_target == "sip:bob@192.168.1.200:5060"
      assert dialog.local_seq == 100
      assert dialog.remote_seq == 0
      assert dialog.state == :confirmed
    end
  end

  describe "create_from_invite/2" do
    test "creates dialog from INVITE request as UAC" do
      invite = %Message{
        type: :request,
        method: :invite,
        request_uri: "sip:bob@example.com",
        from: %From{
          uri: Uri.parse!("sip:alice@alice.com"),
          parameters: %{"tag" => "1928301774"}
        },
        to: %To{
          uri: Uri.parse!("sip:bob@example.com"),
          parameters: %{}
        },
        call_id: "a84b4c76e66710@pc33.atlanta.com",
        cseq: %CSeq{number: 314_159, method: :invite},
        other_headers: %{}
      }

      {:ok, dialog} = Dialog.create_from_invite(invite, :uac)

      assert dialog.call_id == "a84b4c76e66710@pc33.atlanta.com"
      assert dialog.local_tag == "1928301774"
      assert dialog.remote_tag == nil
      assert dialog.state == :early
      assert dialog.role == :uac
    end

    test "creates dialog from INVITE request as UAS" do
      invite = %Message{
        type: :request,
        method: :invite,
        request_uri: "sip:bob@example.com",
        from: %From{
          uri: Uri.parse!("sip:alice@alice.com"),
          parameters: %{"tag" => "1928301774"}
        },
        to: %To{
          uri: Uri.parse!("sip:bob@example.com"),
          parameters: %{}
        },
        call_id: "a84b4c76e66710@pc33.atlanta.com",
        cseq: %CSeq{number: 314_159, method: :invite},
        other_headers: %{}
      }

      {:ok, dialog} = Dialog.create_from_invite(invite, :uas)

      assert dialog.call_id == "a84b4c76e66710@pc33.atlanta.com"
      # UAS generates a tag
      assert dialog.local_tag != nil
      assert dialog.remote_tag == "1928301774"
      assert dialog.state == :early
      assert dialog.role == :uas
    end

    test "returns error for non-INVITE message" do
      bye = %Message{
        type: :request,
        method: :bye,
        request_uri: "sip:bob@example.com",
        other_headers: %{}
      }

      assert {:error, "Message must be an INVITE request"} = Dialog.create_from_invite(bye, :uac)
    end

    test "returns error for invalid role" do
      invite = %Message{
        type: :request,
        method: :invite,
        request_uri: "sip:bob@example.com",
        call_id: "test-call-id",
        other_headers: %{}
      }

      assert {:error, "Role must be :uac or :uas"} = Dialog.create_from_invite(invite, :invalid)
    end
  end

  describe "generate_id/4" do
    test "generates consistent dialog ID" do
      id = Dialog.generate_id(:uac, "call-123", "local-456", "remote-789")

      assert id == "call-123;local=local-456;remote=remote-789;uac"
    end

    test "dialog ID is consistent between UAC and UAS perspectives" do
      # When the same dialog is viewed from different perspectives
      uac_id = Dialog.generate_id(:uac, "call-123", "alice-tag", "bob-tag")
      uas_id = Dialog.generate_id(:uas, "call-123", "bob-tag", "alice-tag")

      # The IDs should be different but related
      assert uac_id == "call-123;local=alice-tag;remote=bob-tag;uac"
      assert uas_id == "call-123;local=bob-tag;remote=alice-tag;uas"
    end
  end

  describe "uas_process/2 - RFC 3261 Section 12.2.2" do
    setup do
      request = %Message{
        method: :invite,
        request_uri: "sip:bob@example.com",
        from: %From{
          uri: Uri.parse!("sip:alice@example.com"),
          parameters: %{"tag" => "from-tag-123"}
        },
        to: %To{
          uri: Uri.parse!("sip:bob@example.com"),
          parameters: %{}
        },
        call_id: "call-123@example.com",
        cseq: %CSeq{number: 100, method: :invite},
        contact: %Contact{
          uri: Uri.parse!("sip:alice@192.168.1.100:5060")
        },
        other_headers: %{}
      }

      response = %Message{
        type: :response,
        status_code: 200,
        from: %From{
          uri: Uri.parse!("sip:alice@example.com"),
          parameters: %{"tag" => "from-tag-123"}
        },
        to: %To{
          uri: Uri.parse!("sip:bob@example.com"),
          parameters: %{"tag" => "to-tag-456"}
        },
        call_id: "call-123@example.com",
        cseq: %CSeq{number: 100, method: :invite},
        other_headers: %{}
      }

      {:ok, dialog} = Dialog.uas_create(request, response)
      {:ok, dialog: dialog}
    end

    test "updates remote sequence number from received request", %{dialog: dialog} do
      options_request = %Message{
        method: :options,
        cseq: %CSeq{number: 150, method: :options},
        other_headers: %{}
      }

      {:ok, updated_dialog} = Dialog.uas_process(options_request, dialog)

      assert updated_dialog.remote_seq == 150
      assert updated_dialog.state == :confirmed
    end

    test "terminates dialog on BYE request", %{dialog: dialog} do
      bye_request = %Message{
        method: :bye,
        cseq: %CSeq{number: 101, method: :bye},
        other_headers: %{}
      }

      {:ok, updated_dialog} = Dialog.uas_process(bye_request, dialog)

      assert updated_dialog.state == :terminated
      assert updated_dialog.remote_seq == 101
    end

    test "maintains state for non-terminating requests", %{dialog: dialog} do
      info_request = %Message{
        method: :info,
        cseq: %CSeq{number: 102, method: :info},
        other_headers: %{}
      }

      {:ok, updated_dialog} = Dialog.uas_process(info_request, dialog)

      assert updated_dialog.state == :confirmed
      assert updated_dialog.remote_seq == 102
    end
  end

  describe "uac_request/2 - RFC 3261 Section 12.2.1.1" do
    setup do
      request = %Message{
        method: :invite,
        request_uri: "sip:bob@example.com",
        from: %From{
          uri: Uri.parse!("sip:alice@example.com"),
          parameters: %{"tag" => "from-tag-123"}
        },
        to: %To{
          uri: Uri.parse!("sip:bob@example.com"),
          parameters: %{}
        },
        call_id: "call-123@example.com",
        cseq: %CSeq{number: 100, method: :invite},
        other_headers: %{}
      }

      response = %Message{
        type: :response,
        status_code: 200,
        from: %From{
          uri: Uri.parse!("sip:alice@example.com"),
          parameters: %{"tag" => "from-tag-123"}
        },
        to: %To{
          uri: Uri.parse!("sip:bob@example.com"),
          parameters: %{"tag" => "to-tag-456"}
        },
        call_id: "call-123@example.com",
        cseq: %CSeq{number: 100, method: :invite},
        contact: %Contact{
          uri: Uri.parse!("sip:bob@192.168.1.200:5060")
        },
        other_headers: %{}
      }

      {:ok, dialog} = Dialog.uac_create(request, response)
      {:ok, dialog: dialog}
    end

    test "increments local sequence number", %{dialog: dialog} do
      initial_seq = dialog.local_seq

      {:ok, _request, updated_dialog} = Dialog.uac_request(:bye, dialog)

      assert updated_dialog.local_seq == initial_seq + 1
    end

    test "creates request with correct From tag", %{dialog: dialog} do
      {:ok, request, _updated_dialog} = Dialog.uac_request(:bye, dialog)

      assert request.from.parameters["tag"] == dialog.local_tag
    end

    test "creates request with correct To tag", %{dialog: dialog} do
      {:ok, request, _updated_dialog} = Dialog.uac_request(:bye, dialog)

      assert request.to.parameters["tag"] == dialog.remote_tag
    end

    test "uses remote target as Request-URI", %{dialog: dialog} do
      {:ok, request, _updated_dialog} = Dialog.uac_request(:bye, dialog)

      assert request.request_uri == dialog.remote_target
    end

    test "sets Call-ID from dialog", %{dialog: dialog} do
      {:ok, request, _updated_dialog} = Dialog.uac_request(:bye, dialog)

      assert request.call_id == dialog.call_id
    end

    test "sets CSeq with incremented number and correct method", %{dialog: dialog} do
      {:ok, request, _updated_dialog} = Dialog.uac_request(:options, dialog)

      assert request.cseq.number == dialog.local_seq + 1
      assert request.cseq.method == :options
    end

    test "multiple requests increment CSeq properly", %{dialog: dialog} do
      {:ok, _req1, dialog1} = Dialog.uac_request(:options, dialog)
      {:ok, req2, dialog2} = Dialog.uac_request(:info, dialog1)
      {:ok, req3, _dialog3} = Dialog.uac_request(:bye, dialog2)

      assert req2.cseq.number == dialog.local_seq + 2
      assert req3.cseq.number == dialog.local_seq + 3
    end
  end

  describe "uac_response/2 - RFC 3261 Section 12.2.1.2" do
    setup do
      request = %Message{
        method: :invite,
        request_uri: "sip:bob@example.com",
        from: %From{
          uri: Uri.parse!("sip:alice@example.com"),
          parameters: %{"tag" => "from-tag-123"}
        },
        to: %To{
          uri: Uri.parse!("sip:bob@example.com"),
          parameters: %{}
        },
        call_id: "call-123@example.com",
        cseq: %CSeq{number: 100, method: :invite},
        other_headers: %{}
      }

      provisional_response = %Message{
        type: :response,
        status_code: 180,
        from: %From{
          uri: Uri.parse!("sip:alice@example.com"),
          parameters: %{"tag" => "from-tag-123"}
        },
        to: %To{
          uri: Uri.parse!("sip:bob@example.com"),
          parameters: %{"tag" => "to-tag-456"}
        },
        call_id: "call-123@example.com",
        cseq: %CSeq{number: 100, method: :invite},
        contact: %Contact{
          uri: Uri.parse!("sip:bob@192.168.1.200:5060")
        },
        other_headers: %{}
      }

      {:ok, early_dialog} = Dialog.uac_create(request, provisional_response)
      {:ok, early_dialog: early_dialog}
    end

    test "transitions from early to confirmed on 2xx to INVITE", %{early_dialog: dialog} do
      final_response = %Message{
        type: :response,
        status_code: 200,
        cseq: %CSeq{number: 100, method: :invite},
        other_headers: %{}
      }

      {:ok, updated_dialog} = Dialog.uac_response(final_response, dialog)

      assert updated_dialog.state == :confirmed
    end

    test "remains early on additional provisional responses", %{early_dialog: dialog} do
      provisional_183 = %Message{
        type: :response,
        status_code: 183,
        cseq: %CSeq{number: 100, method: :invite},
        other_headers: %{}
      }

      {:ok, updated_dialog} = Dialog.uac_response(provisional_183, dialog)

      assert updated_dialog.state == :early
    end

    test "terminates on 2xx to BYE", %{early_dialog: dialog} do
      # First make it confirmed
      final_response = %Message{
        type: :response,
        status_code: 200,
        cseq: %CSeq{number: 100, method: :invite},
        other_headers: %{}
      }

      {:ok, confirmed_dialog} = Dialog.uac_response(final_response, dialog)

      # Then send BYE response
      bye_response = %Message{
        type: :response,
        status_code: 200,
        cseq: %CSeq{number: 101, method: :bye},
        other_headers: %{}
      }

      {:ok, terminated_dialog} = Dialog.uac_response(bye_response, confirmed_dialog)

      assert terminated_dialog.state == :terminated
    end

    test "maintains state for other responses", %{early_dialog: dialog} do
      # First confirm
      final_response = %Message{
        type: :response,
        status_code: 200,
        cseq: %CSeq{number: 100, method: :invite},
        other_headers: %{}
      }

      {:ok, confirmed_dialog} = Dialog.uac_response(final_response, dialog)

      # Then get OPTIONS response
      options_response = %Message{
        type: :response,
        status_code: 200,
        cseq: %CSeq{number: 101, method: :options},
        other_headers: %{}
      }

      {:ok, updated_dialog} = Dialog.uac_response(options_response, confirmed_dialog)

      assert updated_dialog.state == :confirmed
    end
  end

  describe "is_early?/1" do
    test "returns true for early dialog" do
      dialog = %Dialog{state: :early}
      assert Dialog.is_early?(dialog)
    end

    test "returns false for confirmed dialog" do
      dialog = %Dialog{state: :confirmed}
      refute Dialog.is_early?(dialog)
    end

    test "returns false for terminated dialog" do
      dialog = %Dialog{state: :terminated}
      refute Dialog.is_early?(dialog)
    end
  end

  describe "is_secure?/1" do
    test "returns true for secure dialog" do
      dialog = %Dialog{secure: true}
      assert Dialog.is_secure?(dialog)
    end

    test "returns false for non-secure dialog" do
      dialog = %Dialog{secure: false}
      refute Dialog.is_secure?(dialog)
    end
  end

  describe "secure (SIPS) dialogs - RFC 3261 Section 26" do
    test "uas_create sets secure flag for SIPS URI" do
      request = %Message{
        method: :invite,
        request_uri: "sips:bob@example.com",
        from: %From{
          uri: Uri.parse!("sip:alice@example.com"),
          parameters: %{"tag" => "from-tag-123"}
        },
        to: %To{
          uri: Uri.parse!("sip:bob@example.com"),
          parameters: %{}
        },
        call_id: "call-123@example.com",
        cseq: %CSeq{number: 100, method: :invite},
        contact: %Contact{
          uri: Uri.parse!("sip:alice@192.168.1.100:5060")
        },
        other_headers: %{}
      }

      response = %Message{
        type: :response,
        status_code: 200,
        from: request.from,
        to: %To{
          uri: Uri.parse!("sip:bob@example.com"),
          parameters: %{"tag" => "to-tag-456"}
        },
        call_id: "call-123@example.com",
        cseq: %CSeq{number: 100, method: :invite},
        other_headers: %{}
      }

      {:ok, dialog} = Dialog.uas_create(request, response)

      assert dialog.secure == true
    end

    test "uac_create sets secure flag for SIPS URI" do
      request = %Message{
        method: :invite,
        request_uri: "sips:bob@example.com",
        from: %From{
          uri: Uri.parse!("sip:alice@example.com"),
          parameters: %{"tag" => "from-tag-123"}
        },
        to: %To{
          uri: Uri.parse!("sip:bob@example.com"),
          parameters: %{}
        },
        call_id: "call-123@example.com",
        cseq: %CSeq{number: 100, method: :invite},
        other_headers: %{}
      }

      response = %Message{
        type: :response,
        status_code: 200,
        from: request.from,
        to: %To{
          uri: Uri.parse!("sip:bob@example.com"),
          parameters: %{"tag" => "to-tag-456"}
        },
        call_id: "call-123@example.com",
        cseq: %CSeq{number: 100, method: :invite},
        contact: %Contact{
          uri: Uri.parse!("sip:bob@192.168.1.200:5060")
        },
        other_headers: %{}
      }

      {:ok, dialog} = Dialog.uac_create(request, response)

      assert dialog.secure == true
    end

    test "non-SIPS URI sets secure flag to false" do
      request = %Message{
        method: :invite,
        request_uri: "sip:bob@example.com",
        from: %From{
          uri: Uri.parse!("sip:alice@example.com"),
          parameters: %{"tag" => "from-tag-123"}
        },
        to: %To{
          uri: Uri.parse!("sip:bob@example.com"),
          parameters: %{}
        },
        call_id: "call-123@example.com",
        cseq: %CSeq{number: 100, method: :invite},
        contact: %Contact{
          uri: Uri.parse!("sip:alice@192.168.1.100:5060")
        },
        other_headers: %{}
      }

      response = %Message{
        type: :response,
        status_code: 200,
        from: request.from,
        to: %To{
          uri: Uri.parse!("sip:bob@example.com"),
          parameters: %{"tag" => "to-tag-456"}
        },
        call_id: "call-123@example.com",
        cseq: %CSeq{number: 100, method: :invite},
        other_headers: %{}
      }

      {:ok, dialog} = Dialog.uas_create(request, response)

      assert dialog.secure == false
    end
  end

  describe "error handling" do
    test "create_from_invite returns error for missing Call-ID" do
      invite = %Message{
        method: :invite,
        call_id: nil,
        from: %From{
          uri: Uri.parse!("sip:alice@example.com"),
          parameters: %{"tag" => "from-tag-123"}
        },
        to: %To{
          uri: Uri.parse!("sip:bob@example.com"),
          parameters: %{}
        },
        cseq: %CSeq{number: 100, method: :invite},
        other_headers: %{}
      }

      assert {:error, :no_call_id} = Dialog.create_from_invite(invite, :uac)
    end

    test "create_from_invite returns error for missing From tag" do
      invite = %Message{
        method: :invite,
        call_id: "call-123@example.com",
        from: %From{
          uri: Uri.parse!("sip:alice@example.com"),
          parameters: %{}
        },
        to: %To{
          uri: Uri.parse!("sip:bob@example.com"),
          parameters: %{}
        },
        cseq: %CSeq{number: 100, method: :invite},
        other_headers: %{}
      }

      assert {:error, :no_from_tag} = Dialog.create_from_invite(invite, :uac)
    end

    test "is_complete? handles nil tags" do
      dialog_id = %{
        call_id: "call-123",
        local_tag: nil,
        remote_tag: nil
      }

      refute Dialog.is_complete?(dialog_id)
    end

    test "from_message handles message with nil From header" do
      message = %Message{
        type: :request,
        direction: :incoming,
        from: nil,
        to: %To{parameters: %{}},
        call_id: "call-123@example.com",
        other_headers: %{}
      }

      dialog_id = Dialog.from_message(message)

      assert dialog_id.local_tag == nil
      assert dialog_id.remote_tag == nil
    end

    test "from_message handles message with nil To header" do
      message = %Message{
        type: :request,
        direction: :incoming,
        from: %From{parameters: %{"tag" => "from-tag"}},
        to: nil,
        call_id: "call-123@example.com",
        other_headers: %{}
      }

      dialog_id = Dialog.from_message(message)

      assert dialog_id.local_tag == "from-tag"
      assert dialog_id.remote_tag == nil
    end
  end

  describe "full dialog lifecycle - RFC 3261 Section 12" do
    test "UAC: INVITE → 180 → 200 → BYE → 200" do
      # UAC sends INVITE
      invite = %Message{
        method: :invite,
        request_uri: "sip:bob@example.com",
        from: %From{
          uri: Uri.parse!("sip:alice@example.com"),
          parameters: %{"tag" => "alice-tag"}
        },
        to: %To{
          uri: Uri.parse!("sip:bob@example.com"),
          parameters: %{}
        },
        call_id: "lifecycle-test@example.com",
        cseq: %CSeq{number: 1, method: :invite},
        other_headers: %{}
      }

      # Receives 180 Ringing
      ringing_response = %Message{
        type: :response,
        status_code: 180,
        from: invite.from,
        to: %To{
          uri: Uri.parse!("sip:bob@example.com"),
          parameters: %{"tag" => "bob-tag"}
        },
        call_id: "lifecycle-test@example.com",
        cseq: %CSeq{number: 1, method: :invite},
        contact: %Contact{
          uri: Uri.parse!("sip:bob@192.168.1.200:5060")
        },
        other_headers: %{}
      }

      {:ok, early_dialog} = Dialog.uac_create(invite, ringing_response)
      assert early_dialog.state == :early

      # Receives 200 OK
      ok_response = %Message{ringing_response | status_code: 200}
      {:ok, confirmed_dialog} = Dialog.uac_response(ok_response, early_dialog)
      assert confirmed_dialog.state == :confirmed

      # UAC sends BYE
      {:ok, bye_request, dialog_after_bye} = Dialog.uac_request(:bye, confirmed_dialog)
      assert bye_request.method == :bye
      assert bye_request.cseq.number == confirmed_dialog.local_seq + 1

      # Receives 200 OK to BYE
      bye_ok_response = %Message{
        type: :response,
        status_code: 200,
        cseq: %CSeq{number: bye_request.cseq.number, method: :bye},
        other_headers: %{}
      }

      {:ok, terminated_dialog} = Dialog.uac_response(bye_ok_response, dialog_after_bye)
      assert terminated_dialog.state == :terminated
    end

    test "UAS: receives INVITE → sends 180 → sends 200 → receives BYE" do
      # UAS receives INVITE
      invite = %Message{
        method: :invite,
        request_uri: "sip:bob@example.com",
        from: %From{
          uri: Uri.parse!("sip:alice@example.com"),
          parameters: %{"tag" => "alice-tag"}
        },
        to: %To{
          uri: Uri.parse!("sip:bob@example.com"),
          parameters: %{}
        },
        call_id: "uas-lifecycle-test@example.com",
        cseq: %CSeq{number: 1, method: :invite},
        contact: %Contact{
          uri: Uri.parse!("sip:alice@192.168.1.100:5060")
        },
        other_headers: %{}
      }

      # UAS sends 180
      ringing_response = %Message{
        type: :response,
        status_code: 180,
        from: invite.from,
        to: %To{
          uri: Uri.parse!("sip:bob@example.com"),
          parameters: %{"tag" => "bob-tag"}
        },
        call_id: "uas-lifecycle-test@example.com",
        cseq: %CSeq{number: 1, method: :invite},
        other_headers: %{}
      }

      {:ok, early_dialog} = Dialog.uas_create(invite, ringing_response)
      assert early_dialog.state == :early

      # UAS sends 200 OK
      ok_response = %Message{ringing_response | status_code: 200}
      {:ok, confirmed_dialog} = Dialog.uas_create(invite, ok_response)
      assert confirmed_dialog.state == :confirmed

      # UAS receives BYE
      bye_request = %Message{
        method: :bye,
        cseq: %CSeq{number: 2, method: :bye},
        other_headers: %{}
      }

      {:ok, terminated_dialog} = Dialog.uas_process(bye_request, confirmed_dialog)
      assert terminated_dialog.state == :terminated
    end
  end
end
