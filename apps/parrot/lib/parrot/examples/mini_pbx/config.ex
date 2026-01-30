defmodule Parrot.Examples.MiniPBX.Config do
  @moduledoc """
  Configuration helpers for the Mini PBX example.

  Provides configuration for:
  - Extension ranges and validation
  - Outbound routing prefixes
  - Domain settings
  - Auto-attendant menu options

  ## Example

      # Check if extension is valid
      Config.valid_extension?("1001")  #=> true

      # Build AOR from extension
      Config.extension_aor("1001")  #=> "sip:1001@pbx.local"

      # Check if outbound call
      Config.outbound_call?("91234567890")  #=> true
  """

  @extension_range 1000..1999
  @outbound_prefix "9"
  @domain "pbx.local"
  @auto_attendant_extension "100"

  # ============================================================================
  # Extension Configuration
  # ============================================================================

  @doc """
  Returns the valid extension number range.

  Default: 1000-1999 (4-digit extensions starting with 1)
  """
  @spec extension_range() :: Range.t()
  def extension_range, do: @extension_range

  @doc """
  Checks if the given number is a valid extension.

  ## Examples

      Config.valid_extension?("1001")  #=> true
      Config.valid_extension?("2001")  #=> false
  """
  @spec valid_extension?(String.t()) :: boolean()
  def valid_extension?(number) when is_binary(number) do
    case Integer.parse(number) do
      {n, ""} -> n in @extension_range
      _ -> false
    end
  end

  # ============================================================================
  # Outbound Routing Configuration
  # ============================================================================

  @doc """
  Returns the outbound dialing prefix.

  Calls starting with this prefix are routed to PSTN.
  Default: "9"
  """
  @spec outbound_prefix() :: String.t()
  def outbound_prefix, do: @outbound_prefix

  @doc """
  Checks if a dialed number is an outbound (PSTN) call.

  ## Examples

      Config.outbound_call?("91234567890")  #=> true
      Config.outbound_call?("1001")         #=> false
  """
  @spec outbound_call?(String.t()) :: boolean()
  def outbound_call?(number) when is_binary(number) do
    String.starts_with?(number, @outbound_prefix)
  end

  @doc """
  Strips the outbound prefix from a dialed number.

  Returns the original number if it doesn't have the prefix.

  ## Examples

      Config.strip_outbound_prefix("91234567890")  #=> "1234567890"
      Config.strip_outbound_prefix("1001")         #=> "1001"
  """
  @spec strip_outbound_prefix(String.t()) :: String.t()
  def strip_outbound_prefix(number) when is_binary(number) do
    if outbound_call?(number) do
      String.slice(number, String.length(@outbound_prefix)..-1//1)
    else
      number
    end
  end

  # ============================================================================
  # Domain Configuration
  # ============================================================================

  @doc """
  Returns the PBX domain name.

  Used for building SIP URIs and AORs.
  Default: "pbx.local"
  """
  @spec domain() :: String.t()
  def domain, do: @domain

  @doc """
  Builds an Address of Record (AOR) from an extension number.

  ## Examples

      Config.extension_aor("1001")  #=> "sip:1001@pbx.local"
  """
  @spec extension_aor(String.t()) :: String.t()
  def extension_aor(extension) when is_binary(extension) do
    "sip:#{extension}@#{@domain}"
  end

  # ============================================================================
  # Auto-Attendant Configuration
  # ============================================================================

  @doc """
  Returns the auto-attendant extension number.

  Default: "100"
  """
  @spec auto_attendant_extension() :: String.t()
  def auto_attendant_extension, do: @auto_attendant_extension

  @doc """
  Returns the auto-attendant menu options.

  Returns a map of DTMF digit -> action tuples.

  ## Default Options

  - "1" - Company directory
  - "2" - Sales department
  - "3" - Support department
  - "0" - Operator
  - "*" - Repeat menu
  """
  @spec auto_attendant_options() :: map()
  def auto_attendant_options do
    %{
      "1" => {:directory, "Company Directory"},
      "2" => {:transfer, "1010", "Sales Department"},
      "3" => {:transfer, "1020", "Support Department"},
      "0" => {:transfer, "1000", "Operator"},
      "*" => {:repeat, "Repeat menu"}
    }
  end
end
