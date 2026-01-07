defmodule Parrot.CallTest do
  use ExUnit.Case, async: true

  alias Parrot.Call

  describe "struct definition" do
    test "creates a call with default values" do
      call = %Call{}

      assert call.assigns == %{}
      assert call.from == nil
      assert call.to == nil
      assert call.method == nil
      assert call.__operations__ == []
    end

    test "creates a call with provided values" do
      call = %Call{
        from: "sip:alice@example.com",
        to: "sip:bob@example.com",
        method: "INVITE",
        assigns: %{custom: :value}
      }

      assert call.from == "sip:alice@example.com"
      assert call.to == "sip:bob@example.com"
      assert call.method == "INVITE"
      assert call.assigns == %{custom: :value}
    end
  end

  describe "new/1" do
    test "creates a call from keyword options" do
      call =
        Call.new(
          from: "sip:alice@example.com",
          to: "sip:bob@example.com",
          method: "INVITE"
        )

      assert call.from == "sip:alice@example.com"
      assert call.to == "sip:bob@example.com"
      assert call.method == "INVITE"
      assert call.assigns == %{}
      assert call.__operations__ == []
    end

    test "creates a call with empty options" do
      call = Call.new([])

      assert call.from == nil
      assert call.to == nil
      assert call.method == nil
      assert call.assigns == %{}
      assert call.__operations__ == []
    end
  end

  describe "answer/1" do
    test "adds answer operation with no options" do
      call = %Call{} |> Call.answer()

      assert [operation] = call.__operations__
      assert operation == {:answer, []}
    end

    test "chains with other operations" do
      call =
        %Call{}
        |> Call.answer()
        |> Call.answer()

      assert length(call.__operations__) == 2
    end
  end

  describe "answer/2" do
    test "adds answer operation with SDP options" do
      sdp_opts = [codecs: [:pcmu, :pcma]]
      call = %Call{} |> Call.answer(sdp_opts)

      assert [operation] = call.__operations__
      assert operation == {:answer, [codecs: [:pcmu, :pcma]]}
    end
  end

  describe "reject/2" do
    test "adds reject operation with status code" do
      call = %Call{} |> Call.reject(486)

      assert [operation] = call.__operations__
      assert operation == {:reject, 486}
    end

    test "adds reject operation with 403 Forbidden" do
      call = %Call{} |> Call.reject(403)

      assert [operation] = call.__operations__
      assert operation == {:reject, 403}
    end
  end

  describe "hangup/1" do
    test "adds hangup operation" do
      call = %Call{} |> Call.hangup()

      assert [operation] = call.__operations__
      assert operation == {:hangup, []}
    end
  end

  describe "assign/3" do
    test "adds a key-value pair to assigns" do
      call = %Call{} |> Call.assign(:menu, :main)

      assert call.assigns == %{menu: :main}
    end

    test "chains multiple assigns" do
      call =
        %Call{}
        |> Call.assign(:menu, :main)
        |> Call.assign(:retries, 0)
        |> Call.assign(:caller_id, "alice")

      assert call.assigns == %{menu: :main, retries: 0, caller_id: "alice"}
    end

    test "overwrites existing keys" do
      call =
        %Call{assigns: %{menu: :main}}
        |> Call.assign(:menu, :sales)

      assert call.assigns == %{menu: :sales}
    end
  end

  describe "play/2" do
    test "adds play operation with single file" do
      call = %Call{} |> Call.play("welcome.wav")

      assert [operation] = call.__operations__
      assert operation == {:play, "welcome.wav", []}
    end

    test "adds play operation with list of files" do
      files = ["intro.wav", "menu.wav"]
      call = %Call{} |> Call.play(files)

      assert [operation] = call.__operations__
      assert operation == {:play, files, []}
    end
  end

  describe "play/3" do
    test "adds play operation with loop option" do
      call = %Call{} |> Call.play("music.wav", loop: true)

      assert [operation] = call.__operations__
      assert operation == {:play, "music.wav", [loop: true]}
    end

    test "adds play operation with multiple options" do
      call = %Call{} |> Call.play("audio.wav", loop: true, volume: 0.8)

      assert [operation] = call.__operations__
      assert operation == {:play, "audio.wav", [loop: true, volume: 0.8]}
    end
  end

  describe "record/2" do
    test "adds record operation with filename" do
      call = %Call{} |> Call.record("recording.wav")

      assert [operation] = call.__operations__
      assert operation == {:record, "recording.wav", []}
    end
  end

  describe "record/3" do
    test "adds record operation with max_duration option" do
      call = %Call{} |> Call.record("recording.wav", max_duration: 60_000)

      assert [operation] = call.__operations__
      assert operation == {:record, "recording.wav", [max_duration: 60_000]}
    end

    test "adds record operation with beep option" do
      call = %Call{} |> Call.record("recording.wav", beep: true)

      assert [operation] = call.__operations__
      assert operation == {:record, "recording.wav", [beep: true]}
    end

    test "adds record operation with multiple options" do
      call = %Call{} |> Call.record("recording.wav", max_duration: 60_000, beep: true)

      assert [operation] = call.__operations__
      assert operation == {:record, "recording.wav", [max_duration: 60_000, beep: true]}
    end
  end

  describe "stop_record/1" do
    test "adds stop_record operation" do
      call = %Call{} |> Call.stop_record()

      assert [operation] = call.__operations__
      assert operation == {:stop_record, []}
    end
  end

  describe "collect_dtmf/2" do
    test "adds collect_dtmf operation with max option" do
      call = %Call{} |> Call.collect_dtmf(max: 4)

      assert [operation] = call.__operations__
      assert operation == {:collect_dtmf, [max: 4]}
    end

    test "adds collect_dtmf operation with timeout option" do
      call = %Call{} |> Call.collect_dtmf(timeout: 5_000)

      assert [operation] = call.__operations__
      assert operation == {:collect_dtmf, [timeout: 5_000]}
    end

    test "adds collect_dtmf operation with terminators option" do
      call = %Call{} |> Call.collect_dtmf(max: 16, terminators: ["#"])

      assert [operation] = call.__operations__
      assert operation == {:collect_dtmf, [max: 16, terminators: ["#"]]}
    end

    test "adds collect_dtmf operation with all options" do
      call = %Call{} |> Call.collect_dtmf(max: 4, timeout: 5_000, terminators: ["#", "*"])

      assert [operation] = call.__operations__
      assert operation == {:collect_dtmf, [max: 4, timeout: 5_000, terminators: ["#", "*"]]}
    end
  end

  describe "prompt/3" do
    test "adds prompt operation combining play and collect" do
      call = %Call{} |> Call.prompt("enter-pin.wav", collect: [max: 4])

      assert [operation] = call.__operations__
      assert operation == {:prompt, "enter-pin.wav", [collect: [max: 4]]}
    end

    test "adds prompt operation with timeout in collect options" do
      call = %Call{} |> Call.prompt("enter-pin.wav", collect: [max: 4, timeout: 10_000])

      assert [operation] = call.__operations__
      assert operation == {:prompt, "enter-pin.wav", [collect: [max: 4, timeout: 10_000]]}
    end
  end

  describe "bridge/2" do
    test "adds bridge operation with destination" do
      call = %Call{} |> Call.bridge("sip:dest@somewhere")

      assert [operation] = call.__operations__
      assert operation == {:bridge, "sip:dest@somewhere", []}
    end
  end

  describe "bridge/3" do
    test "adds bridge operation with timeout option" do
      call = %Call{} |> Call.bridge("sip:dest@somewhere", timeout: 30_000)

      assert [operation] = call.__operations__
      assert operation == {:bridge, "sip:dest@somewhere", [timeout: 30_000]}
    end

    test "adds bridge operation with headers option" do
      headers = %{"X-Custom" => "value"}
      call = %Call{} |> Call.bridge("sip:dest@somewhere", headers: headers)

      assert [operation] = call.__operations__
      assert operation == {:bridge, "sip:dest@somewhere", [headers: headers]}
    end

    test "adds bridge operation with handler option" do
      call = %Call{} |> Call.bridge("sip:dest@somewhere", handler: SomeBLegHandler)

      assert [operation] = call.__operations__
      assert operation == {:bridge, "sip:dest@somewhere", [handler: SomeBLegHandler]}
    end

    test "adds bridge operation with all options" do
      headers = %{"X-Custom" => "value"}

      call =
        %Call{}
        |> Call.bridge("sip:dest@somewhere",
          timeout: 30_000,
          headers: headers,
          handler: SomeBLegHandler
        )

      assert [operation] = call.__operations__

      assert operation ==
               {:bridge, "sip:dest@somewhere",
                [
                  timeout: 30_000,
                  headers: headers,
                  handler: SomeBLegHandler
                ]}
    end
  end

  describe "fork/2" do
    test "adds fork operation with destinations" do
      destinations = [
        {"sip:alice@device1", handler: Handler1},
        {"sip:alice@device2", handler: Handler2}
      ]

      call = %Call{} |> Call.fork(destinations)

      assert [operation] = call.__operations__
      assert operation == {:fork, destinations, []}
    end
  end

  describe "fork/3" do
    test "adds fork operation with strategy option" do
      destinations = [
        {"sip:alice@device1", []},
        {"sip:alice@device2", []}
      ]

      call = %Call{} |> Call.fork(destinations, strategy: :first_answer)

      assert [operation] = call.__operations__
      assert operation == {:fork, destinations, [strategy: :first_answer]}
    end

    test "adds fork operation with timeout option" do
      destinations = [
        {"sip:alice@device1", []},
        {"sip:alice@device2", []}
      ]

      call = %Call{} |> Call.fork(destinations, timeout: 30_000)

      assert [operation] = call.__operations__
      assert operation == {:fork, destinations, [timeout: 30_000]}
    end

    test "adds fork operation with all options" do
      destinations = [
        {"sip:alice@device1", handler: Handler1},
        {"sip:alice@device2", handler: Handler2}
      ]

      call = %Call{} |> Call.fork(destinations, strategy: :first_answer, timeout: 30_000)

      assert [operation] = call.__operations__
      assert operation == {:fork, destinations, [strategy: :first_answer, timeout: 30_000]}
    end
  end

  describe "pipeline chaining" do
    test "chains multiple operations in order" do
      call =
        %Call{from: "sip:alice@example.com", to: "sip:100@pbx.local"}
        |> Call.answer()
        |> Call.assign(:menu, :main)
        |> Call.play("welcome.wav")
        |> Call.collect_dtmf(max: 1, timeout: 10_000)

      assert call.assigns == %{menu: :main}

      # Operations should be in order they were added
      assert [
               {:answer, []},
               {:play, "welcome.wav", []},
               {:collect_dtmf, [max: 1, timeout: 10_000]}
             ] = call.__operations__
    end

    test "complex IVR flow" do
      call =
        Call.new(from: "sip:alice@example.com", to: "sip:100@pbx.local", method: "INVITE")
        |> Call.answer()
        |> Call.assign(:menu, :main)
        |> Call.assign(:retries, 0)
        |> Call.play("welcome.wav")
        |> Call.prompt("main-menu.wav", collect: [max: 1, timeout: 10_000])

      assert call.from == "sip:alice@example.com"
      assert call.to == "sip:100@pbx.local"
      assert call.method == "INVITE"
      assert call.assigns == %{menu: :main, retries: 0}

      assert [
               {:answer, []},
               {:play, "welcome.wav", []},
               {:prompt, "main-menu.wav", [collect: [max: 1, timeout: 10_000]]}
             ] = call.__operations__
    end

    test "reject flow" do
      call =
        %Call{}
        |> Call.reject(486)

      assert [{:reject, 486}] = call.__operations__
    end

    test "bridge flow with recording" do
      call =
        %Call{}
        |> Call.answer()
        |> Call.record("call-recording.wav", beep: false)
        |> Call.bridge("sip:agent@call-center")
        |> Call.stop_record()

      assert [
               {:answer, []},
               {:record, "call-recording.wav", [beep: false]},
               {:bridge, "sip:agent@call-center", []},
               {:stop_record, []}
             ] = call.__operations__
    end
  end

  describe "get_operations/1" do
    test "returns operations in execution order" do
      call =
        %Call{}
        |> Call.answer()
        |> Call.play("welcome.wav")
        |> Call.hangup()

      operations = Call.get_operations(call)

      assert operations == [
               {:answer, []},
               {:play, "welcome.wav", []},
               {:hangup, []}
             ]
    end

    test "returns empty list for call with no operations" do
      call = %Call{}

      assert Call.get_operations(call) == []
    end
  end
end
