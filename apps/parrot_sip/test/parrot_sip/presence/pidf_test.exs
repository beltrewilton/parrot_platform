defmodule ParrotSip.Presence.PidfTest do
  @moduledoc """
  Tests for PIDF (Presence Information Data Format) XML generation.

  RFC 3863 defines the PIDF format for presence information.
  """
  use ExUnit.Case, async: true

  alias ParrotSip.Presence.Pidf

  describe "build/2" do
    test "generates valid PIDF+XML for open status" do
      presentity = "sip:alice@example.com"
      presence_state = %{status: :open, note: "Available"}

      xml = Pidf.build(presentity, presence_state)

      # RFC 3863 Section 4.1 - PIDF root element
      assert xml =~ ~r/<\?xml version="1\.0"\?>/
      assert xml =~ ~r/<presence.*xmlns="urn:ietf:params:xml:ns:pidf"/
      assert xml =~ ~r/entity="sip:alice@example\.com"/

      # RFC 3863 Section 4.1.2 - tuple element
      assert xml =~ ~r/<tuple id=/

      # RFC 3863 Section 4.1.4 - status element with basic
      assert xml =~ ~r/<status><basic>open<\/basic><\/status>/

      # RFC 3863 Section 4.1.5 - note element
      assert xml =~ ~r/<note>Available<\/note>/
    end

    test "generates valid PIDF+XML for closed status" do
      presentity = "sip:bob@example.com"
      presence_state = %{status: :closed, note: "On a call"}

      xml = Pidf.build(presentity, presence_state)

      assert xml =~ ~r/<presence.*entity="sip:bob@example\.com"/
      assert xml =~ ~r/<status><basic>closed<\/basic><\/status>/
      assert xml =~ ~r/<note>On a call<\/note>/
    end

    test "generates PIDF+XML without note when not provided" do
      presentity = "sip:carol@example.com"
      presence_state = %{status: :open}

      xml = Pidf.build(presentity, presence_state)

      assert xml =~ ~r/<presence.*entity="sip:carol@example\.com"/
      assert xml =~ ~r/<status><basic>open<\/basic><\/status>/
      refute xml =~ ~r/<note>/
    end

    test "generates unique tuple ID" do
      presentity = "sip:alice@example.com"
      presence_state = %{status: :open}

      xml1 = Pidf.build(presentity, presence_state)
      xml2 = Pidf.build(presentity, presence_state)

      # Extract tuple IDs
      [_, id1] = Regex.run(~r/<tuple id="([^"]+)"/, xml1)
      [_, id2] = Regex.run(~r/<tuple id="([^"]+)"/, xml2)

      assert id1 != id2
    end

    test "handles special characters in note" do
      presentity = "sip:alice@example.com"
      presence_state = %{status: :open, note: "Available <for calls> & meetings"}

      xml = Pidf.build(presentity, presence_state)

      # XML entities should be escaped
      assert xml =~ ~r/<note>Available &lt;for calls&gt; &amp; meetings<\/note>/
    end

    test "handles presentity URI with various formats" do
      # Standard SIP URI
      xml1 = Pidf.build("sip:user@domain.com", %{status: :open})
      assert xml1 =~ ~r/entity="sip:user@domain\.com"/

      # SIP URI with port
      xml2 = Pidf.build("sip:user@domain.com:5060", %{status: :open})
      assert xml2 =~ ~r/entity="sip:user@domain\.com:5060"/

      # SIP URI with IP address
      xml3 = Pidf.build("sip:100@192.168.1.1", %{status: :open})
      assert xml3 =~ ~r/entity="sip:100@192\.168\.1\.1"/
    end
  end

  describe "content_type/0" do
    test "returns correct content type for PIDF+XML" do
      # RFC 3863 Section 6 - Media Type Registration
      assert Pidf.content_type() == "application/pidf+xml"
    end
  end
end
