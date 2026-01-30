defmodule Parrot.Examples.MiniPBX.OutboundTest do
  @moduledoc """
  Tests for the Mini PBX Outbound PSTN handler.

  Tests outbound calling with:
  - Dial 9 + number for outside line
  - Number validation
  - Multi-carrier fork with failover
  - Error handling
  """
  use ExUnit.Case, async: true

  alias Parrot.Call
  alias Parrot.Examples.MiniPBX.Outbound

  describe "handle_invite/1" do
    test "valid number answers and forks to carriers" do
      call =
        Call.new(
          from: "sip:1001@pbx.local",
          to: "sip:91234567890@pbx.local",
          method: "INVITE"
        )

      result = Outbound.handle_invite(call)

      operations = result.__operations__

      # Should answer
      assert Enum.any?(operations, &match?({:answer, _}, &1))

      # Should fork to carriers
      assert Enum.any?(operations, &match?({:fork, _, _}, &1))

      # Should store dialed number
      assert result.assigns[:dialed_number] == "1234567890"
    end

    test "rejects invalid short number" do
      call =
        Call.new(
          from: "sip:1001@pbx.local",
          to: "sip:9123@pbx.local",
          method: "INVITE"
        )

      result = Outbound.handle_invite(call)

      operations = result.__operations__
      assert Enum.any?(operations, &match?({:reject, 404}, &1))
    end

    test "rejects number with invalid characters" do
      call =
        Call.new(
          from: "sip:1001@pbx.local",
          to: "sip:9abc1234567@pbx.local",
          method: "INVITE"
        )

      result = Outbound.handle_invite(call)

      operations = result.__operations__
      assert Enum.any?(operations, &match?({:reject, 404}, &1))
    end

    test "accepts valid 10-digit number" do
      call =
        Call.new(
          from: "sip:1001@pbx.local",
          to: "sip:95551234567@pbx.local",
          method: "INVITE"
        )

      result = Outbound.handle_invite(call)

      operations = result.__operations__
      assert Enum.any?(operations, &match?({:fork, _, _}, &1))
      assert result.assigns[:dialed_number] == "5551234567"
    end

    test "accepts valid international number (up to 15 digits)" do
      call =
        Call.new(
          from: "sip:1001@pbx.local",
          to: "sip:9447911234567@pbx.local",
          method: "INVITE"
        )

      result = Outbound.handle_invite(call)

      operations = result.__operations__
      assert Enum.any?(operations, &match?({:fork, _, _}, &1))
      assert result.assigns[:dialed_number] == "447911234567"
    end

    test "stores caller info" do
      call =
        Call.new(
          from: "sip:1001@pbx.local",
          to: "sip:91234567890@pbx.local",
          method: "INVITE"
        )

      result = Outbound.handle_invite(call)

      assert result.assigns[:caller] == "sip:1001@pbx.local"
    end
  end

  describe "handle_fork_complete/2" do
    test "answered returns noreply" do
      call =
        Call.new(
          from: "sip:1001@pbx.local",
          to: "sip:91234567890@pbx.local"
        )
        |> Call.assign(:dialed_number, "1234567890")

      result = Outbound.handle_fork_complete({:answered, "sip:1234567890@carrier1.com"}, call)

      assert match?({:noreply, _}, result)
    end

    test "all_failed plays error and hangs up" do
      call =
        Call.new(
          from: "sip:1001@pbx.local",
          to: "sip:91234567890@pbx.local"
        )
        |> Call.assign(:dialed_number, "1234567890")

      result = Outbound.handle_fork_complete({:failed, :all_failed}, call)

      result_call = case result do
        {:noreply, c} -> c
        c -> c
      end

      operations = result_call.__operations__

      # Should play error and hangup
      assert Enum.any?(operations, fn
        {:play, filename, _} -> String.contains?(filename, "cannot") or String.contains?(filename, "error")
        _ -> false
      end)
      assert Enum.any?(operations, &match?({:hangup, _}, &1))
    end
  end

  describe "validate_number/1" do
    test "validates E.164 format" do
      assert Outbound.validate_number("1234567890") == {:ok, "1234567890"}
      assert Outbound.validate_number("12345678901234") == {:ok, "12345678901234"}
    end

    test "rejects too short numbers" do
      assert Outbound.validate_number("123456789") == {:error, :invalid}
    end

    test "rejects too long numbers" do
      assert Outbound.validate_number("1234567890123456") == {:error, :invalid}
    end

    test "rejects non-digit characters" do
      assert Outbound.validate_number("123-456-7890") == {:error, :invalid}
      assert Outbound.validate_number("1234abc567") == {:error, :invalid}
    end
  end

  describe "build_destinations/1" do
    test "builds destination list for all carriers" do
      destinations = Outbound.build_destinations("1234567890")

      assert is_list(destinations)
      assert length(destinations) >= 1

      # Each destination should be a SIP URI
      Enum.each(destinations, fn dest ->
        assert is_binary(dest) or is_tuple(dest)
      end)
    end
  end
end
