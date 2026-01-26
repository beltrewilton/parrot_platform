defmodule Parrot.CallB2BUAOpsTest do
  @moduledoc """
  Tests for B2BUA DSL operations in Parrot.Call.

  These operations support softswitch capabilities:
  - originate - Create outbound legs
  - connect_legs - Connect two legs for media bridging
  - hold/resume - Put legs on/off hold
  - transfer - Blind and attended transfers
  - hangup_leg - Hang up specific legs

  RFC References:
  - RFC 3261 Section 16 - B2BUA patterns
  - RFC 5765 - B2BUA requirements
  - RFC 3515 - REFER method (transfers)
  """
  use ExUnit.Case, async: true

  alias Parrot.Call

  # ===========================================================================
  # originate/2 - Create outbound leg with default options
  # ===========================================================================

  describe "originate/2" do
    test "adds originate operation with destination" do
      call = %Call{} |> Call.originate("sip:dest@pbx.local")

      assert [operation] = call.__operations__
      assert operation == {:originate, "sip:dest@pbx.local", []}
    end

    test "works with different SIP URIs" do
      call = %Call{} |> Call.originate("sip:agent@call-center.example.com")

      assert [operation] = call.__operations__
      assert operation == {:originate, "sip:agent@call-center.example.com", []}
    end
  end

  # ===========================================================================
  # originate/3 - Create outbound leg with options
  # ===========================================================================

  describe "originate/3" do
    test "adds originate operation with :as option for custom leg ID" do
      call = %Call{} |> Call.originate("sip:dest@pbx.local", as: :b_leg)

      assert [operation] = call.__operations__
      assert operation == {:originate, "sip:dest@pbx.local", [as: :b_leg]}
    end

    test "adds originate operation with string leg ID" do
      call = %Call{} |> Call.originate("sip:dest@pbx.local", as: "custom-leg-id")

      assert [operation] = call.__operations__
      assert operation == {:originate, "sip:dest@pbx.local", [as: "custom-leg-id"]}
    end

    test "adds originate operation with timeout option" do
      call = %Call{} |> Call.originate("sip:dest@pbx.local", timeout: 30_000)

      assert [operation] = call.__operations__
      assert operation == {:originate, "sip:dest@pbx.local", [timeout: 30_000]}
    end

    test "adds originate operation with headers option" do
      headers = %{"X-Custom-Header" => "value", "X-Call-Priority" => "high"}
      call = %Call{} |> Call.originate("sip:dest@pbx.local", headers: headers)

      assert [operation] = call.__operations__
      assert operation == {:originate, "sip:dest@pbx.local", [headers: headers]}
    end

    test "adds originate operation with all options" do
      headers = %{"X-Custom" => "value"}

      call =
        %Call{}
        |> Call.originate("sip:dest@pbx.local",
          as: :b_leg,
          timeout: 30_000,
          headers: headers
        )

      assert [operation] = call.__operations__

      assert operation ==
               {:originate, "sip:dest@pbx.local",
                [as: :b_leg, timeout: 30_000, headers: headers]}
    end

    test "chains with other operations" do
      call =
        %Call{}
        |> Call.answer()
        |> Call.originate("sip:agent@pbx.local", as: :b_leg)

      operations = Call.get_operations(call)

      assert [
               {:answer, []},
               {:originate, "sip:agent@pbx.local", [as: :b_leg]}
             ] = operations
    end
  end

  # ===========================================================================
  # connect_legs/3 - Connect two legs for media bridging
  # ===========================================================================

  describe "connect_legs/3" do
    test "adds connect_legs operation with two leg IDs" do
      call = %Call{} |> Call.connect_legs(:a_leg, :b_leg)

      assert [operation] = call.__operations__
      assert operation == {:connect_legs, :a_leg, :b_leg, []}
    end

    test "works with string leg IDs" do
      call = %Call{} |> Call.connect_legs("leg-1", "leg-2")

      assert [operation] = call.__operations__
      assert operation == {:connect_legs, "leg-1", "leg-2", []}
    end

    test "works with mixed leg ID types" do
      call = %Call{} |> Call.connect_legs(:a_leg, "custom-b-leg")

      assert [operation] = call.__operations__
      assert operation == {:connect_legs, :a_leg, "custom-b-leg", []}
    end

    test "chains with originate operations" do
      call =
        %Call{}
        |> Call.answer()
        |> Call.originate("sip:agent@pbx.local", as: :b_leg)
        |> Call.connect_legs(:a_leg, :b_leg)

      operations = Call.get_operations(call)

      assert [
               {:answer, []},
               {:originate, "sip:agent@pbx.local", [as: :b_leg]},
               {:connect_legs, :a_leg, :b_leg, []}
             ] = operations
    end
  end

  # ===========================================================================
  # connect_legs/4 - Connect two legs with options
  # ===========================================================================

  describe "connect_legs/4" do
    test "adds connect_legs operation with media mode option" do
      call = %Call{} |> Call.connect_legs(:a_leg, :b_leg, media: :proxy)

      assert [operation] = call.__operations__
      assert operation == {:connect_legs, :a_leg, :b_leg, [media: :proxy]}
    end

    test "adds connect_legs operation with direct media mode" do
      call = %Call{} |> Call.connect_legs(:a_leg, :b_leg, media: :direct)

      assert [operation] = call.__operations__
      assert operation == {:connect_legs, :a_leg, :b_leg, [media: :direct]}
    end
  end

  # ===========================================================================
  # hold/2 - Put a leg on hold
  # ===========================================================================

  describe "hold/2" do
    test "adds hold operation with leg ID atom" do
      call = %Call{} |> Call.hold(:b_leg)

      assert [operation] = call.__operations__
      assert operation == {:hold, :b_leg}
    end

    test "adds hold operation with leg ID string" do
      call = %Call{} |> Call.hold("custom-leg-id")

      assert [operation] = call.__operations__
      assert operation == {:hold, "custom-leg-id"}
    end

    test "chains with other operations" do
      call =
        %Call{}
        |> Call.answer()
        |> Call.bridge("sip:agent@pbx.local")
        |> Call.hold(:b_leg)

      operations = Call.get_operations(call)

      assert [
               {:answer, []},
               {:bridge, "sip:agent@pbx.local", []},
               {:hold, :b_leg}
             ] = operations
    end
  end

  # ===========================================================================
  # resume/2 - Resume a held leg
  # ===========================================================================

  describe "resume/2" do
    test "adds resume operation with leg ID atom" do
      call = %Call{} |> Call.resume(:b_leg)

      assert [operation] = call.__operations__
      assert operation == {:resume, :b_leg}
    end

    test "adds resume operation with leg ID string" do
      call = %Call{} |> Call.resume("custom-leg-id")

      assert [operation] = call.__operations__
      assert operation == {:resume, "custom-leg-id"}
    end

    test "chains with hold operation" do
      call =
        %Call{}
        |> Call.hold(:b_leg)
        |> Call.play("hold-music.wav")
        |> Call.resume(:b_leg)

      operations = Call.get_operations(call)

      assert [
               {:hold, :b_leg},
               {:play, "hold-music.wav", []},
               {:resume, :b_leg}
             ] = operations
    end
  end

  # ===========================================================================
  # transfer/3 - Blind transfer
  # ===========================================================================

  describe "transfer/3" do
    test "adds transfer operation with leg ID and destination (blind transfer)" do
      call = %Call{} |> Call.transfer(:b_leg, "sip:new-agent@pbx.local")

      assert [operation] = call.__operations__
      assert operation == {:transfer, :b_leg, "sip:new-agent@pbx.local", []}
    end

    test "works with string leg ID" do
      call = %Call{} |> Call.transfer("custom-leg", "sip:dest@example.com")

      assert [operation] = call.__operations__
      assert operation == {:transfer, "custom-leg", "sip:dest@example.com", []}
    end

    test "chains with other operations" do
      call =
        %Call{}
        |> Call.answer()
        |> Call.bridge("sip:agent@pbx.local")
        |> Call.transfer(:b_leg, "sip:supervisor@pbx.local")

      operations = Call.get_operations(call)

      assert [
               {:answer, []},
               {:bridge, "sip:agent@pbx.local", []},
               {:transfer, :b_leg, "sip:supervisor@pbx.local", []}
             ] = operations
    end
  end

  # ===========================================================================
  # transfer/4 - Transfer with options (blind or attended)
  # ===========================================================================

  describe "transfer/4" do
    test "adds transfer operation with type: :blind (default)" do
      call = %Call{} |> Call.transfer(:b_leg, "sip:new@pbx.local", type: :blind)

      assert [operation] = call.__operations__
      assert operation == {:transfer, :b_leg, "sip:new@pbx.local", [type: :blind]}
    end

    test "adds transfer operation with type: :attended" do
      call = %Call{} |> Call.transfer(:b_leg, "sip:new@pbx.local", type: :attended)

      assert [operation] = call.__operations__
      assert operation == {:transfer, :b_leg, "sip:new@pbx.local", [type: :attended]}
    end

    test "adds transfer operation with timeout option" do
      call = %Call{} |> Call.transfer(:b_leg, "sip:new@pbx.local", timeout: 30_000)

      assert [operation] = call.__operations__
      assert operation == {:transfer, :b_leg, "sip:new@pbx.local", [timeout: 30_000]}
    end

    test "adds transfer operation with headers option" do
      headers = %{"Referred-By" => "sip:operator@pbx.local"}

      call =
        %Call{}
        |> Call.transfer(:b_leg, "sip:new@pbx.local", headers: headers)

      assert [operation] = call.__operations__
      assert operation == {:transfer, :b_leg, "sip:new@pbx.local", [headers: headers]}
    end

    test "adds transfer operation with all options" do
      headers = %{"Referred-By" => "sip:operator@pbx.local"}

      call =
        %Call{}
        |> Call.transfer(:b_leg, "sip:new@pbx.local",
          type: :attended,
          timeout: 30_000,
          headers: headers
        )

      assert [operation] = call.__operations__

      assert operation ==
               {:transfer, :b_leg, "sip:new@pbx.local",
                [type: :attended, timeout: 30_000, headers: headers]}
    end
  end

  # ===========================================================================
  # hangup_leg/2 - Hang up a specific leg
  # ===========================================================================

  describe "hangup_leg/2" do
    test "adds hangup_leg operation with leg ID atom" do
      call = %Call{} |> Call.hangup_leg(:b_leg)

      assert [operation] = call.__operations__
      assert operation == {:hangup_leg, :b_leg}
    end

    test "adds hangup_leg operation with leg ID string" do
      call = %Call{} |> Call.hangup_leg("custom-leg-id")

      assert [operation] = call.__operations__
      assert operation == {:hangup_leg, "custom-leg-id"}
    end

    test "chains with other operations" do
      call =
        %Call{}
        |> Call.answer()
        |> Call.bridge("sip:agent@pbx.local")
        |> Call.hangup_leg(:b_leg)
        |> Call.play("goodbye.wav")
        |> Call.hangup()

      operations = Call.get_operations(call)

      assert [
               {:answer, []},
               {:bridge, "sip:agent@pbx.local", []},
               {:hangup_leg, :b_leg},
               {:play, "goodbye.wav", []},
               {:hangup, []}
             ] = operations
    end
  end

  # ===========================================================================
  # Enhanced bridge/3 - with media mode option
  # ===========================================================================

  describe "bridge/3 with media mode" do
    test "adds bridge operation with media: :proxy option" do
      call = %Call{} |> Call.bridge("sip:agent@pbx.local", media: :proxy)

      assert [operation] = call.__operations__
      assert operation == {:bridge, "sip:agent@pbx.local", [media: :proxy]}
    end

    test "adds bridge operation with media: :direct option" do
      call = %Call{} |> Call.bridge("sip:agent@pbx.local", media: :direct)

      assert [operation] = call.__operations__
      assert operation == {:bridge, "sip:agent@pbx.local", [media: :direct]}
    end

    test "combines media mode with other options" do
      call =
        %Call{}
        |> Call.bridge("sip:agent@pbx.local",
          timeout: 30_000,
          media: :proxy,
          handler: SomeBLegHandler
        )

      assert [operation] = call.__operations__

      assert operation ==
               {:bridge, "sip:agent@pbx.local",
                [timeout: 30_000, media: :proxy, handler: SomeBLegHandler]}
    end
  end

  # ===========================================================================
  # Enhanced fork/3 - with ring strategies
  # ===========================================================================

  describe "fork/3 with ring strategies" do
    test "adds fork operation with strategy: :simultaneous" do
      destinations = ["sip:a@pbx.local", "sip:b@pbx.local"]
      call = %Call{} |> Call.fork(destinations, strategy: :simultaneous)

      assert [operation] = call.__operations__
      assert operation == {:fork, destinations, [strategy: :simultaneous]}
    end

    test "adds fork operation with strategy: :sequential" do
      destinations = ["sip:a@pbx.local", "sip:b@pbx.local"]
      call = %Call{} |> Call.fork(destinations, strategy: :sequential, timeout: 15_000)

      assert [operation] = call.__operations__
      assert operation == {:fork, destinations, [strategy: :sequential, timeout: 15_000]}
    end

    test "adds fork operation with strategy: :delayed and delay option" do
      destinations = ["sip:a@pbx.local", "sip:b@pbx.local"]
      call = %Call{} |> Call.fork(destinations, strategy: :delayed, delay: 5_000)

      assert [operation] = call.__operations__
      assert operation == {:fork, destinations, [strategy: :delayed, delay: 5_000]}
    end

    test "adds fork operation with media mode" do
      destinations = ["sip:a@pbx.local", "sip:b@pbx.local"]
      call = %Call{} |> Call.fork(destinations, strategy: :simultaneous, media: :proxy)

      assert [operation] = call.__operations__
      assert operation == {:fork, destinations, [strategy: :simultaneous, media: :proxy]}
    end
  end

  # ===========================================================================
  # Complex B2BUA flows
  # ===========================================================================

  describe "complex B2BUA flow pipelines" do
    test "simple bridge flow" do
      call =
        %Call{}
        |> Call.answer()
        |> Call.bridge("sip:agent@pbx.local", timeout: 30_000, media: :proxy)

      operations = Call.get_operations(call)

      assert [
               {:answer, []},
               {:bridge, "sip:agent@pbx.local", [timeout: 30_000, media: :proxy]}
             ] = operations
    end

    test "explicit leg control flow" do
      call =
        %Call{}
        |> Call.answer()
        |> Call.originate("sip:dest@pbx.local", as: :b_leg)
        |> Call.connect_legs(:a_leg, :b_leg)

      operations = Call.get_operations(call)

      assert [
               {:answer, []},
               {:originate, "sip:dest@pbx.local", [as: :b_leg]},
               {:connect_legs, :a_leg, :b_leg, []}
             ] = operations
    end

    test "hold and resume flow" do
      call =
        %Call{}
        |> Call.answer()
        |> Call.bridge("sip:agent@pbx.local")
        |> Call.hold(:b_leg)
        |> Call.play("please-hold.wav")
        |> Call.resume(:b_leg)

      operations = Call.get_operations(call)

      assert [
               {:answer, []},
               {:bridge, "sip:agent@pbx.local", []},
               {:hold, :b_leg},
               {:play, "please-hold.wav", []},
               {:resume, :b_leg}
             ] = operations
    end

    test "blind transfer flow" do
      call =
        %Call{}
        |> Call.answer()
        |> Call.bridge("sip:agent@pbx.local")
        |> Call.transfer(:b_leg, "sip:supervisor@pbx.local")

      operations = Call.get_operations(call)

      assert [
               {:answer, []},
               {:bridge, "sip:agent@pbx.local", []},
               {:transfer, :b_leg, "sip:supervisor@pbx.local", []}
             ] = operations
    end

    test "attended transfer flow" do
      call =
        %Call{}
        |> Call.answer()
        |> Call.bridge("sip:agent@pbx.local")
        |> Call.hold(:b_leg)
        |> Call.originate("sip:supervisor@pbx.local", as: :c_leg)
        |> Call.transfer(:b_leg, "sip:supervisor@pbx.local", type: :attended)

      operations = Call.get_operations(call)

      assert [
               {:answer, []},
               {:bridge, "sip:agent@pbx.local", []},
               {:hold, :b_leg},
               {:originate, "sip:supervisor@pbx.local", [as: :c_leg]},
               {:transfer, :b_leg, "sip:supervisor@pbx.local", [type: :attended]}
             ] = operations
    end

    test "fork with fallback handling" do
      destinations = [
        "sip:agent1@pbx.local",
        "sip:agent2@pbx.local",
        "sip:agent3@pbx.local"
      ]

      call =
        %Call{}
        |> Call.answer()
        |> Call.fork(destinations, strategy: :simultaneous, timeout: 30_000)

      operations = Call.get_operations(call)

      assert [
               {:answer, []},
               {:fork, ^destinations, [strategy: :simultaneous, timeout: 30_000]}
             ] = operations
    end

    test "hangup_leg with continued call handling" do
      call =
        %Call{}
        |> Call.answer()
        |> Call.bridge("sip:agent@pbx.local")
        |> Call.hangup_leg(:b_leg)
        |> Call.say("The other party has disconnected. Goodbye.")
        |> Call.hangup()

      operations = Call.get_operations(call)

      assert [
               {:answer, []},
               {:bridge, "sip:agent@pbx.local", []},
               {:hangup_leg, :b_leg},
               {:say, "The other party has disconnected. Goodbye.", []},
               {:hangup, []}
             ] = operations
    end

    test "multi-leg conference-like scenario" do
      call =
        %Call{}
        |> Call.answer()
        |> Call.originate("sip:party-b@pbx.local", as: :b_leg)
        |> Call.originate("sip:party-c@pbx.local", as: :c_leg)
        |> Call.connect_legs(:a_leg, :b_leg)

      operations = Call.get_operations(call)

      assert [
               {:answer, []},
               {:originate, "sip:party-b@pbx.local", [as: :b_leg]},
               {:originate, "sip:party-c@pbx.local", [as: :c_leg]},
               {:connect_legs, :a_leg, :b_leg, []}
             ] = operations
    end
  end
end
