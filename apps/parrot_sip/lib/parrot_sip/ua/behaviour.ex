defmodule ParrotSip.UA.Behaviour do
  @moduledoc """
  Behaviour for implementing SIP User Agents (both client and server).

  This behaviour combines both UAC (client) and UAS (server) callbacks,
  allowing a single module to handle both outgoing and incoming calls.

  ## Example

      defmodule MyUA do
        use ParrotSip.UA.Behaviour

        def init(_config) do
          {:ok, %{calls: %{}}}
        end

        # Client callbacks
        def handle_ringing(180, %Message{} = response, state) do
          IO.puts("Ringing...")
          {:ok, state}
        end

        def handle_answered(200, %Message{} = response, state) do
          IO.puts("Call answered!")
          {:ok, state}
        end

        # Server callbacks
        def handle_incoming_call(%Message{} = invite, %Transaction{} = transaction, state) do
          {:accept, state}
        end

        def handle_bye(%Message{} = bye, state) do
          {:ok, state}
        end
      end

      # Usage
      config = %ParrotSip.UA.Config{
        from: %ParrotSip.Headers.From{uri: "sip:alice@example.com", parameters: %{}},
        outbound_proxy: "sip:proxy.example.com:5060"
      }
      {:ok, ua} = ParrotSip.UA.start_link(MyUA, config)

      # Make a call
      ParrotSip.UA.Client.invite(ua, "sip:bob@example.com")
  """

  alias ParrotSip.{Message, Transaction, Dialog}
  alias ParrotSip.Headers.Contact

  @type state :: term()
  @type status_code :: integer()

  # === Lifecycle ===

  @doc """
  Initializes the UA state.

  Called when UA starts with the provided configuration.

  ## Parameters
  - `config` - ParrotSip.UA.Config struct

  ## Returns
  - `{:ok, state}` - Initial user state
  """
  @callback init(config :: ParrotSip.UA.Config.t()) :: {:ok, state()}

  # === Client Callbacks (Outgoing) ===

  @doc """
  Called when receiving 180 Ringing response.

  ## Parameters
  - `status_code` - The status code (180)
  - `response` - The SIP response Message struct
  - `state` - Current UA state

  ## Returns
  - `{:ok, new_state}` - Continue with new state
  - `{:stop, reason, new_state}` - Stop the UA process
  """
  @callback handle_ringing(status_code(), response :: Message.t(), state :: state()) ::
              {:ok, state()} | {:stop, reason :: term(), state()}

  @doc """
  Called when receiving other 1xx provisional responses (181, 182, 183).

  Optional callback. If not implemented, provisional responses are ignored.

  ## Parameters
  - `status_code` - The status code (181-183)
  - `response` - The SIP response Message struct
  - `state` - Current UA state
  """
  @callback handle_progress(status_code(), response :: Message.t(), state :: state()) ::
              {:ok, state()} | {:stop, reason :: term(), state()}

  @doc """
  Called when receiving 2xx success response.

  ## Parameters
  - `status_code` - The status code (200-299)
  - `response` - The SIP response Message struct
  - `state` - Current UA state
  """
  @callback handle_answered(status_code(), response :: Message.t(), state :: state()) ::
              {:ok, state()} | {:stop, reason :: term(), state()}

  @doc """
  Called when the dialog is established (for INVITE requests).

  Optional callback.

  ## Parameters
  - `dialog` - The established Dialog struct
  - `state` - Current UA state
  """
  @callback handle_established(dialog :: Dialog.t(), state :: state()) ::
              {:ok, state()}

  @doc """
  Called when receiving 3xx redirect response.

  Optional callback. If not implemented, redirects are treated as rejections.

  ## Parameters
  - `status_code` - The status code (300-399)
  - `response` - The SIP response Message struct
  - `contacts` - List of Contact header structs to try
  - `state` - Current UA state

  ## Returns
  - `{:retry, contact, new_state}` - Retry with specific contact
  - `{:stop, reason, new_state}` - Stop
  """
  @callback handle_redirect(
              status_code(),
              response :: Message.t(),
              contacts :: [Contact.t()],
              state :: state()
            ) ::
              {:retry, contact :: Contact.t(), state()}
              | {:stop, reason :: term(), state()}

  @doc """
  Called when receiving 4xx or 5xx error response.

  ## Parameters
  - `status_code` - The status code (400-699)
  - `response` - The SIP response Message struct
  - `state` - Current UA state
  """
  @callback handle_rejected(status_code(), response :: Message.t(), state :: state()) ::
              {:ok, state()} | {:stop, reason :: term(), state()}

  @doc """
  Called when a client transaction timeout occurs.

  ## Parameters
  - `timeout_type` - The timer that fired (`:timer_b` or `:timer_f`)
  - `state` - Current UA state
  """
  @callback handle_timeout(timeout_type :: :timer_b | :timer_f, state :: state()) ::
              {:retry, state()} | {:stop, reason :: term(), state()}

  # === Server Callbacks (Incoming) ===

  @doc """
  Called when receiving an incoming INVITE request.

  ## Parameters
  - `invite` - The INVITE Message struct
  - `transaction` - The Transaction struct
  - `state` - Current UA state

  ## Returns
  - `{:accept, state}` - Accept call immediately with 200 OK
  - `{:accept, sdp_body, state}` - Accept with SDP answer
  - `{:ring, state}` - Send 180 Ringing
  - `{:reject, status_code, reason, state}` - Reject the call
  """
  @callback handle_incoming_call(
              invite :: Message.t(),
              transaction :: Transaction.t(),
              state :: state()
            ) ::
              {:accept, state()}
              | {:accept, sdp_body :: String.t(), state()}
              | {:ring, state()}
              | {:reject, status_code :: integer(), reason :: String.t(), state()}

  @doc """
  Called when receiving ACK for a final response.

  Optional callback.

  ## Parameters
  - `ack` - The ACK Message struct
  - `state` - Current UA state
  """
  @callback handle_ack(ack :: Message.t(), state :: state()) ::
              {:ok, state()}

  @doc """
  Called when receiving BYE request.

  ## Parameters
  - `bye` - The BYE Message struct
  - `state` - Current UA state
  """
  @callback handle_bye(bye :: Message.t(), state :: state()) ::
              {:ok, state()}

  @doc """
  Called when receiving CANCEL request.

  ## Parameters
  - `cancel` - The CANCEL Message struct
  - `state` - Current UA state
  """
  @callback handle_cancel(cancel :: Message.t(), state :: state()) ::
              {:ok, state()}

  # === Registration Callbacks (Optional) ===

  @doc """
  Called before sending REGISTER request.

  Allows modifying the REGISTER message before sending.

  Optional callback.

  ## Parameters
  - `register` - The REGISTER Message struct to be sent
  - `state` - Current UA state

  ## Returns
  - `{:ok, modified_register, new_state}` - Send modified message
  - `{:ok, register, new_state}` - Send unmodified message
  - `{:cancel, new_state}` - Cancel registration
  """
  @callback handle_register(register :: Message.t(), state :: state()) ::
              {:ok, Message.t(), state()} | {:cancel, state()}

  @doc """
  Called when receiving response to REGISTER request.

  Optional callback.

  ## Parameters
  - `status_code` - Response status code
  - `response` - The response Message struct
  - `state` - Current UA state
  """
  @callback handle_register_response(status_code(), response :: Message.t(), state :: state()) ::
              {:ok, state()}

  # Optional callbacks
  @optional_callbacks [
    handle_progress: 3,
    handle_established: 2,
    handle_redirect: 4,
    handle_ack: 2,
    handle_cancel: 2,
    handle_register: 2,
    handle_register_response: 3
  ]

  @doc false
  defmacro __using__(_opts) do
    quote do
      @behaviour ParrotSip.UA.Behaviour

      # Provide default implementations for optional callbacks

      def handle_progress(_status_code, _response, state) do
        {:ok, state}
      end

      def handle_established(_dialog, state) do
        {:ok, state}
      end

      def handle_redirect(status_code, _response, _contacts, state) do
        {:stop, {:redirect, status_code}, state}
      end

      def handle_ack(_ack, state) do
        {:ok, state}
      end

      def handle_cancel(_cancel, state) do
        {:ok, state}
      end

      def handle_register(register, state) do
        {:ok, register, state}
      end

      def handle_register_response(_status_code, _response, state) do
        {:ok, state}
      end

      defoverridable handle_progress: 3,
                     handle_established: 2,
                     handle_redirect: 4,
                     handle_ack: 2,
                     handle_cancel: 2,
                     handle_register: 2,
                     handle_register_response: 3
    end
  end
end
