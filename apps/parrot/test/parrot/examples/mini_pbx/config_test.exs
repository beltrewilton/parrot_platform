defmodule Parrot.Examples.MiniPBX.ConfigTest do
  @moduledoc """
  Tests for the Mini PBX Config module.

  Tests configuration helpers for extensions, outbound trunks, etc.
  """
  use ExUnit.Case, async: true

  alias Parrot.Examples.MiniPBX.Config

  describe "extension configuration" do
    test "returns default extension range" do
      range = Config.extension_range()
      assert range == 1000..1999
    end

    test "validates extension number in range" do
      assert Config.valid_extension?("1001")
      assert Config.valid_extension?("1999")
      refute Config.valid_extension?("2001")
      refute Config.valid_extension?("999")
    end
  end

  describe "outbound routing" do
    test "returns outbound prefix" do
      assert Config.outbound_prefix() == "9"
    end

    test "identifies outbound call by prefix" do
      assert Config.outbound_call?("91234567890")
      refute Config.outbound_call?("1001")
    end

    test "strips outbound prefix for PSTN routing" do
      assert Config.strip_outbound_prefix("91234567890") == "1234567890"
      assert Config.strip_outbound_prefix("1001") == "1001"
    end
  end

  describe "domain configuration" do
    test "returns default domain" do
      assert Config.domain() == "pbx.local"
    end

    test "builds AOR from extension" do
      assert Config.extension_aor("1001") == "sip:1001@pbx.local"
    end
  end

  describe "auto-attendant configuration" do
    test "returns auto-attendant extension" do
      assert Config.auto_attendant_extension() == "100"
    end

    test "returns auto-attendant menu options" do
      options = Config.auto_attendant_options()
      assert is_map(options)
      # Should have at least directory and operator options
      assert Map.has_key?(options, "1")
      assert Map.has_key?(options, "0")
    end
  end
end
