defmodule Parrot.CallBidirectionalWsTest do
  @moduledoc """
  TDD tests for bidirectional WebSocket DSL operations.

  These tests define the expected API for bidirectional WebSocket operations
  in Parrot.Call. They are written BEFORE implementation per TDD methodology.

  Reference: specs/004-bidirectional-ws/contracts/dsl_operations.ex
  """
  use ExUnit.Case, async: true

  alias Parrot.Call

  # ============================================================================
  # connect_bidirectional_ws/2 - Connect with URL only
  # ============================================================================

  describe "connect_bidirectional_ws/2" do
    test "adds connect operation to operations list" do
      call = %Call{} |> Call.connect_bidirectional_ws("wss://api.example.com/stream")

      assert [operation] = Call.get_operations(call)
      assert {:connect_bidirectional_ws, "wss://api.example.com/stream", []} = operation
    end

    test "accepts URL as first argument" do
      url = "wss://api.openai.com/v1/realtime"
      call = %Call{} |> Call.connect_bidirectional_ws(url)

      assert [{:connect_bidirectional_ws, ^url, []}] = Call.get_operations(call)
    end

    test "works with ws:// URLs" do
      call = %Call{} |> Call.connect_bidirectional_ws("ws://localhost:8080/audio")

      assert [{:connect_bidirectional_ws, "ws://localhost:8080/audio", []}] =
               Call.get_operations(call)
    end
  end

  # ============================================================================
  # connect_bidirectional_ws/3 - Connect with URL and options
  # ============================================================================

  describe "connect_bidirectional_ws/3" do
    test "accepts URL and options" do
      opts = [sample_rate: 24000]

      call =
        %Call{}
        |> Call.connect_bidirectional_ws("wss://api.example.com/stream", opts)

      assert [{:connect_bidirectional_ws, "wss://api.example.com/stream", ^opts}] =
               Call.get_operations(call)
    end

    test "options include headers" do
      headers = [{"Authorization", "Bearer token123"}, {"X-Custom", "value"}]
      call = %Call{} |> Call.connect_bidirectional_ws("wss://api.example.com/stream", headers: headers)

      assert [{:connect_bidirectional_ws, _, opts}] = Call.get_operations(call)
      assert Keyword.get(opts, :headers) == headers
    end

    test "options include callback_module" do
      call =
        %Call{}
        |> Call.connect_bidirectional_ws("wss://api.example.com/stream",
          callback_module: MyApp.AICallback
        )

      assert [{:connect_bidirectional_ws, _, opts}] = Call.get_operations(call)
      assert Keyword.get(opts, :callback_module) == MyApp.AICallback
    end

    test "options include callback_state" do
      initial_state = %{session_id: nil, turn_count: 0}

      call =
        %Call{}
        |> Call.connect_bidirectional_ws("wss://api.example.com/stream",
          callback_state: initial_state
        )

      assert [{:connect_bidirectional_ws, _, opts}] = Call.get_operations(call)
      assert Keyword.get(opts, :callback_state) == initial_state
    end

    test "options include inbound_format" do
      call =
        %Call{}
        |> Call.connect_bidirectional_ws("wss://api.example.com/stream", inbound_format: :pcm_16le)

      assert [{:connect_bidirectional_ws, _, opts}] = Call.get_operations(call)
      assert Keyword.get(opts, :inbound_format) == :pcm_16le
    end

    test "options include outbound_format" do
      call =
        %Call{}
        |> Call.connect_bidirectional_ws("wss://api.example.com/stream", outbound_format: :opus)

      assert [{:connect_bidirectional_ws, _, opts}] = Call.get_operations(call)
      assert Keyword.get(opts, :outbound_format) == :opus
    end

    test "options include sample_rate" do
      call =
        %Call{}
        |> Call.connect_bidirectional_ws("wss://api.example.com/stream", sample_rate: 24000)

      assert [{:connect_bidirectional_ws, _, opts}] = Call.get_operations(call)
      assert Keyword.get(opts, :sample_rate) == 24000
    end

    test "supports all options together" do
      headers = [{"Authorization", "Bearer token"}]

      call =
        %Call{}
        |> Call.connect_bidirectional_ws("wss://api.openai.com/v1/realtime",
          headers: headers,
          callback_module: MyApp.OpenAICallback,
          callback_state: %{model: "gpt-4o-realtime"},
          inbound_format: :pcm_16le,
          outbound_format: :pcm_16le,
          sample_rate: 24000
        )

      assert [{:connect_bidirectional_ws, url, opts}] = Call.get_operations(call)
      assert url == "wss://api.openai.com/v1/realtime"
      assert Keyword.get(opts, :headers) == headers
      assert Keyword.get(opts, :callback_module) == MyApp.OpenAICallback
      assert Keyword.get(opts, :callback_state) == %{model: "gpt-4o-realtime"}
      assert Keyword.get(opts, :inbound_format) == :pcm_16le
      assert Keyword.get(opts, :outbound_format) == :pcm_16le
      assert Keyword.get(opts, :sample_rate) == 24000
    end

    test "is pipeable with other Call operations" do
      call =
        %Call{}
        |> Call.answer()
        |> Call.connect_bidirectional_ws("wss://api.example.com/stream",
          callback_module: MyApp.AICallback
        )

      operations = Call.get_operations(call)
      assert length(operations) == 2
      assert {:answer, []} = Enum.at(operations, 0)
      assert {:connect_bidirectional_ws, _, _} = Enum.at(operations, 1)
    end
  end

  # ============================================================================
  # disconnect_bidirectional_ws/1
  # ============================================================================

  describe "disconnect_bidirectional_ws/1" do
    test "adds disconnect operation to operations list" do
      call = %Call{} |> Call.disconnect_bidirectional_ws()

      assert [operation] = Call.get_operations(call)
      assert {:disconnect_bidirectional_ws, []} = operation
    end

    test "is pipeable" do
      call =
        %Call{}
        |> Call.connect_bidirectional_ws("wss://api.example.com/stream")
        |> Call.disconnect_bidirectional_ws()

      operations = Call.get_operations(call)
      assert length(operations) == 2
      assert {:connect_bidirectional_ws, _, _} = Enum.at(operations, 0)
      assert {:disconnect_bidirectional_ws, []} = Enum.at(operations, 1)
    end

    test "can be used in complex pipelines" do
      call =
        %Call{}
        |> Call.answer()
        |> Call.connect_bidirectional_ws("wss://api.example.com/stream")
        |> Call.disconnect_bidirectional_ws()
        |> Call.hangup()

      operations = Call.get_operations(call)
      assert length(operations) == 4
      assert {:answer, []} = Enum.at(operations, 0)
      assert {:connect_bidirectional_ws, _, _} = Enum.at(operations, 1)
      assert {:disconnect_bidirectional_ws, []} = Enum.at(operations, 2)
      assert {:hangup, []} = Enum.at(operations, 3)
    end
  end

  # ============================================================================
  # mute_outbound/1
  # ============================================================================

  describe "mute_outbound/1" do
    test "adds mute outbound operation" do
      call = %Call{} |> Call.mute_outbound()

      assert [operation] = Call.get_operations(call)
      assert {:mute_bidirectional, :outbound} = operation
    end

    test "is pipeable with connect operation" do
      call =
        %Call{}
        |> Call.connect_bidirectional_ws("wss://api.example.com/stream")
        |> Call.mute_outbound()

      operations = Call.get_operations(call)
      assert length(operations) == 2
      assert {:connect_bidirectional_ws, _, _} = Enum.at(operations, 0)
      assert {:mute_bidirectional, :outbound} = Enum.at(operations, 1)
    end
  end

  # ============================================================================
  # unmute_outbound/1
  # ============================================================================

  describe "unmute_outbound/1" do
    test "adds unmute outbound operation" do
      call = %Call{} |> Call.unmute_outbound()

      assert [operation] = Call.get_operations(call)
      assert {:unmute_bidirectional, :outbound} = operation
    end

    test "is pipeable after mute" do
      call =
        %Call{}
        |> Call.mute_outbound()
        |> Call.unmute_outbound()

      operations = Call.get_operations(call)
      assert length(operations) == 2
      assert {:mute_bidirectional, :outbound} = Enum.at(operations, 0)
      assert {:unmute_bidirectional, :outbound} = Enum.at(operations, 1)
    end
  end

  # ============================================================================
  # mute_inbound/1
  # ============================================================================

  describe "mute_inbound/1" do
    test "adds mute inbound operation" do
      call = %Call{} |> Call.mute_inbound()

      assert [operation] = Call.get_operations(call)
      assert {:mute_bidirectional, :inbound} = operation
    end

    test "is pipeable with connect operation" do
      call =
        %Call{}
        |> Call.connect_bidirectional_ws("wss://api.example.com/stream")
        |> Call.mute_inbound()

      operations = Call.get_operations(call)
      assert length(operations) == 2
      assert {:connect_bidirectional_ws, _, _} = Enum.at(operations, 0)
      assert {:mute_bidirectional, :inbound} = Enum.at(operations, 1)
    end
  end

  # ============================================================================
  # unmute_inbound/1
  # ============================================================================

  describe "unmute_inbound/1" do
    test "adds unmute inbound operation" do
      call = %Call{} |> Call.unmute_inbound()

      assert [operation] = Call.get_operations(call)
      assert {:unmute_bidirectional, :inbound} = operation
    end

    test "is pipeable after mute" do
      call =
        %Call{}
        |> Call.mute_inbound()
        |> Call.unmute_inbound()

      operations = Call.get_operations(call)
      assert length(operations) == 2
      assert {:mute_bidirectional, :inbound} = Enum.at(operations, 0)
      assert {:unmute_bidirectional, :inbound} = Enum.at(operations, 1)
    end
  end

  # ============================================================================
  # send_ws_message/2
  # ============================================================================

  describe "send_ws_message/2" do
    test "adds send message operation with message content" do
      message = ~s({"type": "response.create"})
      call = %Call{} |> Call.send_ws_message(message)

      assert [operation] = Call.get_operations(call)
      assert {:send_ws_message, ^message} = operation
    end

    test "accepts JSON string messages" do
      message = Jason.encode!(%{type: "session.update", session: %{voice: "alloy"}})
      call = %Call{} |> Call.send_ws_message(message)

      assert [{:send_ws_message, ^message}] = Call.get_operations(call)
    end

    test "accepts binary messages" do
      binary_data = <<0x01, 0x02, 0x03, 0x04>>
      call = %Call{} |> Call.send_ws_message(binary_data)

      assert [{:send_ws_message, ^binary_data}] = Call.get_operations(call)
    end

    test "is pipeable with connect operation" do
      call =
        %Call{}
        |> Call.connect_bidirectional_ws("wss://api.example.com/stream")
        |> Call.send_ws_message(~s({"type": "init"}))

      operations = Call.get_operations(call)
      assert length(operations) == 2
      assert {:connect_bidirectional_ws, _, _} = Enum.at(operations, 0)
      assert {:send_ws_message, _} = Enum.at(operations, 1)
    end

    test "can send multiple messages in sequence" do
      call =
        %Call{}
        |> Call.send_ws_message(~s({"type": "message1"}))
        |> Call.send_ws_message(~s({"type": "message2"}))
        |> Call.send_ws_message(~s({"type": "message3"}))

      operations = Call.get_operations(call)
      assert length(operations) == 3
      assert {:send_ws_message, ~s({"type": "message1"})} = Enum.at(operations, 0)
      assert {:send_ws_message, ~s({"type": "message2"})} = Enum.at(operations, 1)
      assert {:send_ws_message, ~s({"type": "message3"})} = Enum.at(operations, 2)
    end
  end

  # ============================================================================
  # Auto-cleanup on call end tests (US4)
  # ============================================================================

  describe "auto-cleanup on call end (US4)" do
    test "disconnect_bidirectional_ws/1 adds correct operation to call" do
      call = %Call{} |> Call.disconnect_bidirectional_ws()

      assert [operation] = Call.get_operations(call)
      assert {:disconnect_bidirectional_ws, []} = operation
    end

    test "the operation is pipeable with other operations" do
      call =
        %Call{}
        |> Call.answer()
        |> Call.connect_bidirectional_ws("wss://api.example.com/stream")
        |> Call.send_ws_message(~s({"type": "init"}))
        |> Call.disconnect_bidirectional_ws()
        |> Call.hangup()

      operations = Call.get_operations(call)
      assert length(operations) == 5

      assert {:answer, []} = Enum.at(operations, 0)
      assert {:connect_bidirectional_ws, _, _} = Enum.at(operations, 1)
      assert {:send_ws_message, _} = Enum.at(operations, 2)
      assert {:disconnect_bidirectional_ws, []} = Enum.at(operations, 3)
      assert {:hangup, []} = Enum.at(operations, 4)
    end

    test "disconnect_bidirectional_ws can appear multiple times (for multiple connections)" do
      # Scenario: connect to two different AI services sequentially
      call =
        %Call{}
        |> Call.connect_bidirectional_ws("wss://api.openai.com/stream")
        |> Call.disconnect_bidirectional_ws()
        |> Call.connect_bidirectional_ws("wss://api.elevenlabs.com/stream")
        |> Call.disconnect_bidirectional_ws()

      operations = Call.get_operations(call)
      assert length(operations) == 4

      disconnect_count =
        Enum.count(operations, fn
          {:disconnect_bidirectional_ws, _} -> true
          _ -> false
        end)

      assert disconnect_count == 2
    end

    test "send_ws_message/2 adds correct operation with message content" do
      message = ~s({"type": "response.create", "modalities": ["audio"]})
      call = %Call{} |> Call.send_ws_message(message)

      assert [{:send_ws_message, ^message}] = Call.get_operations(call)
    end

    test "send_ws_message/2 works with binary messages" do
      binary_msg = <<0x00, 0x01, 0x02, 0xFF>>
      call = %Call{} |> Call.send_ws_message(binary_msg)

      assert [{:send_ws_message, ^binary_msg}] = Call.get_operations(call)
    end

    test "send_ws_message/2 can be used after connect in pipeline" do
      call =
        %Call{}
        |> Call.connect_bidirectional_ws("wss://api.example.com/stream")
        |> Call.send_ws_message(~s({"type": "session.update"}))
        |> Call.send_ws_message(~s({"type": "response.create"}))

      operations = Call.get_operations(call)
      assert length(operations) == 3

      assert {:connect_bidirectional_ws, _, _} = Enum.at(operations, 0)
      assert {:send_ws_message, ~s({"type": "session.update"})} = Enum.at(operations, 1)
      assert {:send_ws_message, ~s({"type": "response.create"})} = Enum.at(operations, 2)
    end

    test "bidirectional operations work in complete call lifecycle" do
      # Simulates a full call with AI interaction
      call =
        Call.new(from: "sip:user@example.com", to: "sip:ai@service.local", method: "INVITE")
        |> Call.answer()
        |> Call.play("welcome.wav")
        |> Call.connect_bidirectional_ws("wss://api.openai.com/v1/realtime",
          headers: [{"Authorization", "Bearer token"}],
          callback_module: MyApp.OpenAICallback,
          sample_rate: 24000
        )
        |> Call.send_ws_message(Jason.encode!(%{type: "session.update"}))
        |> Call.mute_outbound()
        |> Call.send_ws_message(Jason.encode!(%{type: "response.create"}))
        |> Call.unmute_outbound()
        |> Call.disconnect_bidirectional_ws()
        |> Call.play("goodbye.wav")
        |> Call.hangup()

      operations = Call.get_operations(call)
      assert length(operations) == 10

      # Verify order
      assert {:answer, []} = Enum.at(operations, 0)
      assert {:play, "welcome.wav", []} = Enum.at(operations, 1)
      assert {:connect_bidirectional_ws, "wss://api.openai.com/v1/realtime", _opts} =
               Enum.at(operations, 2)

      assert {:send_ws_message, _} = Enum.at(operations, 3)
      assert {:mute_bidirectional, :outbound} = Enum.at(operations, 4)
      assert {:send_ws_message, _} = Enum.at(operations, 5)
      assert {:unmute_bidirectional, :outbound} = Enum.at(operations, 6)
      assert {:disconnect_bidirectional_ws, []} = Enum.at(operations, 7)
      assert {:play, "goodbye.wav", []} = Enum.at(operations, 8)
      assert {:hangup, []} = Enum.at(operations, 9)
    end

    test "disconnect before hangup ensures proper cleanup order" do
      # This is the recommended pattern - disconnect WebSocket before hangup
      call =
        %Call{}
        |> Call.connect_bidirectional_ws("wss://api.example.com/stream")
        |> Call.disconnect_bidirectional_ws()
        |> Call.hangup()

      operations = Call.get_operations(call)
      disconnect_index = Enum.find_index(operations, &match?({:disconnect_bidirectional_ws, _}, &1))
      hangup_index = Enum.find_index(operations, &match?({:hangup, _}, &1))

      # disconnect should come before hangup
      assert disconnect_index < hangup_index
    end

    test "hangup without explicit disconnect should still work" do
      # User might forget to disconnect - hangup should handle cleanup
      call =
        %Call{}
        |> Call.connect_bidirectional_ws("wss://api.example.com/stream")
        |> Call.hangup()

      operations = Call.get_operations(call)
      assert length(operations) == 2
      assert {:connect_bidirectional_ws, _, _} = Enum.at(operations, 0)
      assert {:hangup, []} = Enum.at(operations, 1)
    end
  end

  # ============================================================================
  # Complex Pipeline Integration
  # ============================================================================

  describe "complex pipeline integration" do
    test "realistic AI call flow" do
      call =
        Call.new(from: "sip:caller@example.com", to: "sip:ai@service.local", method: "INVITE")
        |> Call.answer()
        |> Call.assign(:ai_provider, :openai)
        |> Call.connect_bidirectional_ws("wss://api.openai.com/v1/realtime",
          headers: [{"Authorization", "Bearer token"}],
          callback_module: MyApp.OpenAICallback,
          sample_rate: 24000
        )
        |> Call.send_ws_message(Jason.encode!(%{type: "session.update"}))

      assert call.from == "sip:caller@example.com"
      assert call.to == "sip:ai@service.local"
      assert call.assigns == %{ai_provider: :openai}

      operations = Call.get_operations(call)
      assert length(operations) == 3
      assert {:answer, []} = Enum.at(operations, 0)
      assert {:connect_bidirectional_ws, _, _} = Enum.at(operations, 1)
      assert {:send_ws_message, _} = Enum.at(operations, 2)
    end

    test "mute/unmute flow during AI response" do
      call =
        %Call{}
        |> Call.connect_bidirectional_ws("wss://api.example.com/stream")
        |> Call.mute_outbound()
        |> Call.send_ws_message(~s({"type": "response.create"}))
        |> Call.unmute_outbound()

      operations = Call.get_operations(call)
      assert length(operations) == 4
      assert {:connect_bidirectional_ws, _, _} = Enum.at(operations, 0)
      assert {:mute_bidirectional, :outbound} = Enum.at(operations, 1)
      assert {:send_ws_message, _} = Enum.at(operations, 2)
      assert {:unmute_bidirectional, :outbound} = Enum.at(operations, 3)
    end

    test "graceful disconnect flow" do
      call =
        %Call{}
        |> Call.answer()
        |> Call.connect_bidirectional_ws("wss://api.example.com/stream")
        |> Call.send_ws_message(~s({"type": "conversation.item.create"}))
        |> Call.disconnect_bidirectional_ws()
        |> Call.play("goodbye.wav")
        |> Call.hangup()

      operations = Call.get_operations(call)
      assert length(operations) == 6
      assert {:answer, []} = Enum.at(operations, 0)
      assert {:connect_bidirectional_ws, _, _} = Enum.at(operations, 1)
      assert {:send_ws_message, _} = Enum.at(operations, 2)
      assert {:disconnect_bidirectional_ws, []} = Enum.at(operations, 3)
      assert {:play, "goodbye.wav", []} = Enum.at(operations, 4)
      assert {:hangup, []} = Enum.at(operations, 5)
    end

    test "operations maintain order with mixed call and bidirectional ws operations" do
      call =
        %Call{}
        |> Call.answer()
        |> Call.play("connecting.wav")
        |> Call.connect_bidirectional_ws("wss://api.example.com/stream")
        |> Call.mute_inbound()
        |> Call.mute_outbound()
        |> Call.unmute_inbound()
        |> Call.unmute_outbound()
        |> Call.disconnect_bidirectional_ws()
        |> Call.hangup()

      operations = Call.get_operations(call)
      assert length(operations) == 9

      assert [
               {:answer, []},
               {:play, "connecting.wav", []},
               {:connect_bidirectional_ws, _, _},
               {:mute_bidirectional, :inbound},
               {:mute_bidirectional, :outbound},
               {:unmute_bidirectional, :inbound},
               {:unmute_bidirectional, :outbound},
               {:disconnect_bidirectional_ws, []},
               {:hangup, []}
             ] = operations
    end
  end
end
