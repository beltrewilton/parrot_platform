defmodule ParrotSip.Presence.Pidf do
  @moduledoc """
  PIDF (Presence Information Data Format) XML generation.

  This module generates PIDF+XML documents as defined in RFC 3863 for
  conveying presence information in SIP NOTIFY messages.

  ## RFC References

  - RFC 3863: Presence Information Data Format (PIDF)
  - RFC 3863 Section 4: PIDF XML Format
  - RFC 3863 Section 4.1: The <presence> element
  - RFC 3863 Section 4.1.2: The <tuple> element
  - RFC 3863 Section 4.1.4: The <status> element
  - RFC 3863 Section 4.1.5: The <note> element
  - RFC 3863 Section 6: Media Type Registration (application/pidf+xml)

  ## Example PIDF Document

      <?xml version="1.0"?>
      <presence xmlns="urn:ietf:params:xml:ns:pidf" entity="sip:alice@example.com">
        <tuple id="alice-1234abcd">
          <status><basic>open</basic></status>
          <note>Available</note>
        </tuple>
      </presence>

  ## Usage

      # Generate PIDF for open status
      xml = ParrotSip.Presence.Pidf.build("sip:alice@example.com", %{status: :open, note: "Available"})

      # Generate PIDF for closed status
      xml = ParrotSip.Presence.Pidf.build("sip:alice@example.com", %{status: :closed, note: "On a call"})

  """

  @pidf_namespace "urn:ietf:params:xml:ns:pidf"

  @doc """
  Returns the MIME content type for PIDF+XML documents.

  Per RFC 3863 Section 6, the media type is `application/pidf+xml`.

  ## Examples

      iex> ParrotSip.Presence.Pidf.content_type()
      "application/pidf+xml"

  """
  @spec content_type() :: String.t()
  def content_type, do: "application/pidf+xml"

  @doc """
  Builds a PIDF+XML document for the given presentity and presence state.

  ## Parameters

  - `presentity` - The SIP URI of the entity whose presence is being reported
  - `presence_state` - A map containing:
    - `:status` - Required. Either `:open` (available) or `:closed` (unavailable)
    - `:note` - Optional. Human-readable description of the presence state

  ## Returns

  A string containing the PIDF+XML document.

  ## Examples

      iex> ParrotSip.Presence.Pidf.build("sip:alice@example.com", %{status: :open, note: "Available"})
      "<?xml version=\\"1.0\\"?>\\n<presence xmlns=\\"urn:ietf:params:xml:ns:pidf\\" entity=\\"sip:alice@example.com\\">\\n  <tuple id=\\"...\\">"...

  ## RFC References

  - RFC 3863 Section 4.1: Root <presence> element with entity attribute
  - RFC 3863 Section 4.1.2: <tuple> element with unique id attribute
  - RFC 3863 Section 4.1.4: <status><basic> element (open/closed)
  - RFC 3863 Section 4.1.5: Optional <note> element

  """
  @spec build(String.t(), map()) :: String.t()
  def build(presentity, presence_state) do
    status = Map.fetch!(presence_state, :status)
    note = Map.get(presence_state, :note)
    tuple_id = generate_tuple_id()

    """
    <?xml version="1.0"?>
    <presence xmlns="#{@pidf_namespace}" entity="#{escape_xml(presentity)}">
      <tuple id="#{tuple_id}">
        <status><basic>#{format_status(status)}</basic></status>#{format_note(note)}
      </tuple>
    </presence>
    """
    |> String.trim()
  end

  # RFC 3863 Section 4.1.4: basic status values are "open" or "closed"
  defp format_status(:open), do: "open"
  defp format_status(:closed), do: "closed"

  # RFC 3863 Section 4.1.5: <note> element is optional
  defp format_note(nil), do: ""
  defp format_note(note), do: "\n        <note>#{escape_xml(note)}</note>"

  # RFC 3863 Section 4.1.2: tuple id must be unique
  defp generate_tuple_id do
    # Generate a unique tuple ID using timestamp and random bytes
    timestamp = System.system_time(:microsecond)
    random = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
    "t#{timestamp}-#{random}"
  end

  # Escape XML special characters per XML 1.0 spec
  defp escape_xml(string) do
    string
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&apos;")
  end
end
