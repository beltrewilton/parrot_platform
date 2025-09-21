defmodule ParrotSip.Validators do
  @moduledoc """
  Input validation for SIP messages and parameters.

  This module provides comprehensive validation functions for SIP-related data
  to ensure security and correctness of the protocol implementation.
  """

  alias ParrotSip.{Message, Uri}

  @doc """
  Validates a SIP URI.

  ## Examples

      iex> ParrotSip.Validators.validate_uri("sip:alice@example.com")
      :ok
      
      iex> ParrotSip.Validators.validate_uri("invalid-uri")
      {:error, :invalid_uri_format}
  """
  @spec validate_uri(String.t()) :: :ok | {:error, atom()}
  def validate_uri(uri_string) when is_binary(uri_string) do
    case Uri.parse(uri_string) do
      {:ok, %Uri{scheme: scheme, host: host}} when scheme in ["sip", "sips"] and host != nil ->
        :ok

      {:ok, _} ->
        {:error, :invalid_uri_scheme}

      {:error, _} ->
        {:error, :invalid_uri_format}
    end
  end

  def validate_uri(_), do: {:error, :invalid_uri_type}

  @doc """
  Validates SDP content.

  ## Examples

      iex> sdp = "v=0\\r\\no=- 123 456 IN IP4 192.168.1.1\\r\\ns=-\\r\\nc=IN IP4 192.168.1.1\\r\\nt=0 0\\r\\n"
      iex> ParrotSip.Validators.validate_sdp(sdp)
      :ok
  """
  @spec validate_sdp(String.t()) :: :ok | {:error, atom()}
  def validate_sdp(sdp) when is_binary(sdp) do
    # Basic SDP validation - check for required fields
    lines = String.split(sdp, "\r\n", trim: true)

    required_prefixes = ["v=", "o=", "s="]

    has_required =
      Enum.all?(required_prefixes, fn prefix ->
        Enum.any?(lines, &String.starts_with?(&1, prefix))
      end)

    if has_required do
      validate_sdp_content(lines)
    else
      {:error, :missing_required_sdp_fields}
    end
  end

  def validate_sdp(_), do: {:error, :invalid_sdp_type}

  @doc """
  Validates a SIP method.

  ## Examples

      iex> ParrotSip.Validators.validate_method(:invite)
      :ok
      
      iex> ParrotSip.Validators.validate_method(:unknown)
      {:error, :unsupported_method}
  """
  @spec validate_method(atom()) :: :ok | {:error, atom()}
  def validate_method(method) when is_atom(method) do
    allowed_methods = [:invite, :ack, :bye, :cancel, :options, :register, :info, :prack, :update]

    if method in allowed_methods do
      :ok
    else
      {:error, :unsupported_method}
    end
  end

  def validate_method(_), do: {:error, :invalid_method_type}

  @doc """
  Validates a complete SIP message.

  ## Examples

      iex> message = %ParrotSip.Message{method: :invite, type: :request, headers: %{"via" => []}}
      iex> ParrotSip.Validators.validate_message(message)
      {:error, :missing_required_headers}
  """
  @spec validate_message(Message.t()) :: :ok | {:error, atom()}
  def validate_message(%Message{type: :request} = message) do
    with :ok <- validate_method(message.method),
         :ok <- validate_required_headers(message, [:via, :from, :to, :call_id, :cseq]),
         :ok <- validate_request_uri(message.request_uri) do
      :ok
    end
  end

  def validate_message(%Message{type: :response} = message) do
    with :ok <- validate_status_code(message.status_code),
         :ok <- validate_required_headers(message, [:via, :from, :to, :call_id, :cseq]) do
      :ok
    end
  end

  def validate_message(_), do: {:error, :invalid_message_type}

  @doc """
  Validates a SIP status code.

  ## Examples

      iex> ParrotSip.Validators.validate_status_code(200)
      :ok
      
      iex> ParrotSip.Validators.validate_status_code(999)
      {:error, :invalid_status_code}
  """
  @spec validate_status_code(integer()) :: :ok | {:error, atom()}
  def validate_status_code(code) when is_integer(code) and code >= 100 and code <= 699 do
    :ok
  end

  def validate_status_code(_), do: {:error, :invalid_status_code}

  # Private functions

  defp validate_sdp_content(lines) do
    # Additional SDP validation can be added here
    # For now, just check that lines are formatted correctly
    valid_format =
      Enum.all?(lines, fn line ->
        String.match?(line, ~r/^[a-z]=.*$/)
      end)

    if valid_format do
      :ok
    else
      {:error, :invalid_sdp_format}
    end
  end

  defp validate_required_headers(message, required_headers) do
    missing =
      Enum.reject(required_headers, fn header ->
        has_header_field?(message, header)
      end)

    if Enum.empty?(missing) do
      :ok
    else
      {:error, :missing_required_headers}
    end
  end

  # Check if a message has a specific header field
  defp has_header_field?(%Message{} = message, header) do
    header_name = normalize_header_name(header)

    # First try to find the field in the Message struct
    field_atom = header_name_to_field_atom(header_name)

    if (field_atom in Message.__struct__()) |> Map.keys() do
      # It's a known struct field, check if it's not nil
      not is_nil(Map.get(message, field_atom))
    else
      # It's an unknown header, check in other_headers
      Map.has_key?(message.other_headers || %{}, header_name)
    end
  end

  # Convert header name to the corresponding struct field atom
  defp header_name_to_field_atom(header_name) do
    case header_name do
      "call-id" -> :call_id
      "call_id" -> :call_id
      "max-forwards" -> :max_forwards
      "max_forwards" -> :max_forwards
      "content-type" -> :content_type
      "content_type" -> :content_type
      "content-length" -> :content_length
      "content_length" -> :content_length
      "record-route" -> :record_route
      "record_route" -> :record_route
      "subscription-state" -> :subscription_state
      "subscription_state" -> :subscription_state
      "refer-to" -> :refer_to
      "refer_to" -> :refer_to
      # For most headers, just convert string to atom
      _ -> String.to_existing_atom(header_name)
    end
  rescue
    ArgumentError ->
      # If the atom doesn't exist, it's not a struct field
      :unknown_field
  end

  defp normalize_header_name(header) when is_atom(header) do
    header
    |> Atom.to_string()
    |> String.replace("_", "-")
    |> String.downcase()
  end

  defp normalize_header_name(header) when is_binary(header) do
    String.downcase(header)
  end

  defp validate_request_uri(uri) when is_binary(uri) do
    if String.starts_with?(uri, "sip:") or String.starts_with?(uri, "sips:") do
      :ok
    else
      {:error, :invalid_request_uri}
    end
  end

  defp validate_request_uri(_), do: {:error, :invalid_request_uri}
end
