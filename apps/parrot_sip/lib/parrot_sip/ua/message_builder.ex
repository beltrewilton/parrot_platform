defmodule ParrotSip.UA.MessageBuilder do
  @moduledoc """
  Builds SIP messages from UA configuration.

  This module provides functions to build SIP request messages (INVITE, REGISTER, BYE, etc.)
  using the UA configuration and existing ParrotSip functions.
  """

  alias ParrotSip.{Message, Uri}
  alias ParrotSip.Headers.{Via, CSeq, To, CallId}
  alias ParrotSip.UA.Config

  @doc """
  Builds an INVITE request.

  ## Parameters
  - `config` - UA configuration with From, Contact, and transport info
  - `to_uri` - Target URI string (e.g., "sip:bob@example.com")
  - `opts` - Optional parameters:
    - `:headers` - Additional custom headers (map)
    - `:body` - SDP body (string)
    - `:cseq` - CSeq number (default: 1)

  ## Returns
  - `{:ok, %Message{}}` - Built INVITE message
  - `{:error, reason}` - If URI parsing or validation fails
  """
  @spec build_invite(Config.t(), String.t(), keyword()) :: {:ok, Message.t()} | {:error, term()}
  def build_invite(%Config{} = config, to_uri, opts \\ []) do
    with {:ok, request_uri} <- parse_uri(to_uri),
         {:ok, to_header} <- build_to_header(to_uri),
         {:ok, via_header} <- build_via_header(config) do
      cseq_number = Keyword.get(opts, :cseq, 1)
      custom_headers = Keyword.get(opts, :headers, %{})
      body = Keyword.get(opts, :body)

      message = %Message{
        type: :request,
        method: :invite,
        request_uri: request_uri,
        version: "SIP/2.0",
        via: [via_header],
        from: config.from,
        to: to_header,
        call_id: CallId.generate(),
        cseq: CSeq.new(cseq_number, :invite),
        contact: config.contact && [config.contact],
        other_headers: Map.merge(config.headers, custom_headers),
        body: body,
        source: nil
      }

      {:ok, message}
    end
  end

  @doc """
  Builds a REGISTER request.

  ## Parameters
  - `config` - UA configuration with From, Contact, and registration settings
  - `opts` - Optional parameters:
    - `:headers` - Additional custom headers (map)
    - `:cseq` - CSeq number (default: 1)
    - `:expires` - Expires value (default: from config.registration.expires or 3600)

  ## Returns
  - `{:ok, %Message{}}` - Built REGISTER message
  - `{:error, reason}` - If outbound_proxy is not configured
  """
  @spec build_register(Config.t(), keyword()) :: {:ok, Message.t()} | {:error, term()}
  def build_register(config, opts \\ [])

  def build_register(%Config{outbound_proxy: nil}, _opts) do
    {:error, :outbound_proxy_required}
  end

  def build_register(%Config{} = config, opts) do
    # REGISTER uses From URI as both request URI and To
    request_uri_string = extract_uri_from_from(config.from)

    with {:ok, request_uri} <- parse_uri(request_uri_string),
         {:ok, to_header} <- build_to_header(request_uri_string),
         {:ok, via_header} <- build_via_header(config) do
      cseq_number = Keyword.get(opts, :cseq, 1)
      custom_headers = Keyword.get(opts, :headers, %{})

      expires =
        Keyword.get(
          opts,
          :expires,
          (config.registration && config.registration.expires) || 3600
        )

      message = %Message{
        type: :request,
        method: :register,
        request_uri: request_uri,
        version: "SIP/2.0",
        via: [via_header],
        from: config.from,
        to: to_header,
        call_id: CallId.generate(),
        cseq: CSeq.new(cseq_number, :register),
        contact: config.contact && [config.contact],
        expires: expires,
        other_headers: Map.merge(config.headers, custom_headers),
        body: nil,
        source: nil
      }

      {:ok, message}
    end
  end

  @doc """
  Builds a BYE request.

  ## Parameters
  - `config` - UA configuration
  - `dialog` - Dialog struct with remote target and route set
  - `opts` - Optional parameters:
    - `:headers` - Additional custom headers (map)
    - `:cseq` - CSeq number (required for in-dialog requests)

  ## Returns
  - `{:ok, %Message{}}` - Built BYE message
  - `{:error, reason}` - If dialog or cseq is missing
  """
  @spec build_bye(Config.t(), ParrotSip.Dialog.t(), keyword()) ::
          {:ok, Message.t()} | {:error, term()}
  def build_bye(%Config{} = config, dialog, opts \\ []) do
    # BYE uses dialog's remote target as request URI
    request_uri = dialog.remote_target

    with {:ok, via_header} <- build_via_header(config) do
      cseq_number = Keyword.fetch!(opts, :cseq)
      custom_headers = Keyword.get(opts, :headers, %{})

      message = %Message{
        type: :request,
        method: :bye,
        request_uri: request_uri,
        version: "SIP/2.0",
        via: [via_header],
        from: dialog.local_uri,
        to: dialog.remote_uri,
        call_id: dialog.call_id,
        cseq: CSeq.new(cseq_number, :bye),
        contact: config.contact && [config.contact],
        other_headers: Map.merge(config.headers, custom_headers),
        body: nil,
        source: nil
      }

      {:ok, message}
    end
  end

  # Private Helpers

  @spec parse_uri(String.t() | Uri.t()) :: {:ok, Uri.t()} | {:error, term()}
  defp parse_uri(%Uri{} = uri), do: {:ok, uri}

  defp parse_uri(uri_string) when is_binary(uri_string) do
    Uri.parse(uri_string)
  end

  @spec build_to_header(String.t()) :: {:ok, To.t()} | {:error, term()}
  defp build_to_header(uri_string) do
    to_header = To.new(uri_string, nil, %{})
    {:ok, to_header}
  end

  @spec build_via_header(Config.t()) :: {:ok, Via.t()} | {:error, term()}
  defp build_via_header(%Config{local_host: nil}) do
    {:error, :local_host_required}
  end

  defp build_via_header(%Config{} = config) do
    via =
      Via.new_with_branch(
        config.local_host,
        config.transport,
        config.local_port,
        %{}
      )

    {:ok, via}
  end

  @spec extract_uri_from_from(ParrotSip.Headers.From.t()) :: String.t()
  defp extract_uri_from_from(%{uri: %Uri{} = uri}) do
    # Rebuild URI string from struct
    uri_string = "#{uri.scheme}:"
    uri_string = if uri.user, do: uri_string <> uri.user <> "@", else: uri_string
    uri_string = uri_string <> uri.host
    uri_string = if uri.port, do: uri_string <> ":" <> to_string(uri.port), else: uri_string
    uri_string
  end

  defp extract_uri_from_from(%{uri: uri_string}) when is_binary(uri_string) do
    uri_string
  end
end
