defmodule Parrot.BLegHandler do
  @moduledoc """
  Behaviour for controlling the outbound leg (B-leg) when bridging calls.

  The BLegHandler provides fine-grained control over the outbound INVITE
  and subsequent SIP signaling for advanced call bridging scenarios.

  ## Usage

  Use `use Parrot.BLegHandler` in your module to get default implementations
  of all callbacks and import helper functions for INVITE manipulation:

      defmodule MyApp.BLegHandler do
        use Parrot.BLegHandler

        def before_invite(invite, state) do
          invite
          |> put_header("X-Original-Caller", state.original_caller)
          |> put_header("X-Custom", "value")
          |> remove_header("X-Internal")
          |> modify_sdp(&add_custom_attribute/1)
        end

        def handle_provisional(%{status: 180} = _response, bleg) do
          {:ring, bleg}  # play ring-back to A-leg
        end

        def handle_provisional(%{status: 183} = _response, bleg) do
          {:early_media, bleg}  # connect early media
        end

        def handle_answer(_response, bleg) do
          {:connect, bleg}
        end

        def handle_reject(response, bleg) do
          {:rejected, response.status, bleg}
        end
      end

  ## Callbacks

  All callbacks receive relevant SIP message data and B-leg state:

  ### Required (but has defaults)

  - `before_invite/2` - Manipulate INVITE before sending to destination
  - `handle_provisional/2` - Handle 1xx responses (180 Ringing, 183 Session Progress)
  - `handle_answer/2` - Handle 2xx answer from B-leg
  - `handle_reject/2` - Handle 4xx/5xx/6xx rejection from B-leg
  - `handle_reinvite/2` - Handle in-dialog re-INVITEs
  - `handle_bye/2` - Handle BYE from B-leg

  ## Helper Functions

  The following helper functions are imported when using this behaviour:

  - `put_header/3` - Add or update a header on the INVITE
  - `remove_header/2` - Remove a header from the INVITE
  - `modify_sdp/2` - Apply a transformation function to the SDP body

  """

  alias Parrot.BLeg

  @doc """
  Called before sending the INVITE to the B-leg destination.

  Use this callback to manipulate headers, modify the SDP, or make any
  changes to the outgoing INVITE request.

  ## Arguments

  - `invite` - Map containing the INVITE request (`:headers`, `:body`, etc.)
  - `state` - Handler state containing context from the A-leg

  ## Return

  Return the modified invite map.

  ## Example

      def before_invite(invite, state) do
        invite
        |> put_header("X-Original-Caller", state.original_caller)
        |> remove_header("X-Private-Data")
      end
  """
  @callback before_invite(invite :: map(), state :: map()) :: map()

  @doc """
  Called when a provisional (1xx) response is received from the B-leg.

  ## Arguments

  - `response` - Map containing the response (`:status`, `:reason`, etc.)
  - `bleg` - The current B-leg state

  ## Return

  - `{:ring, bleg}` - Play ring-back tone to A-leg (typically for 180)
  - `{:early_media, bleg}` - Connect early media to A-leg (typically for 183)
  - `{:continue, bleg}` - No action, continue waiting

  ## Example

      def handle_provisional(%{status: 180} = _response, bleg) do
        {:ring, bleg}
      end

      def handle_provisional(%{status: 183} = _response, bleg) do
        {:early_media, bleg}
      end
  """
  @callback handle_provisional(response :: map(), bleg :: BLeg.t()) ::
              {:ring, BLeg.t()} | {:early_media, BLeg.t()} | {:continue, BLeg.t()}

  @doc """
  Called when a 2xx response is received from the B-leg (call answered).

  ## Arguments

  - `response` - Map containing the 200 OK response
  - `bleg` - The current B-leg state

  ## Return

  - `{:connect, bleg}` - Connect media between A-leg and B-leg

  ## Example

      def handle_answer(_response, bleg) do
        {:connect, bleg}
      end
  """
  @callback handle_answer(response :: map(), bleg :: BLeg.t()) :: {:connect, BLeg.t()}

  @doc """
  Called when a 4xx/5xx/6xx response is received from the B-leg (call rejected).

  ## Arguments

  - `response` - Map containing the rejection response
  - `bleg` - The current B-leg state

  ## Return

  - `{:rejected, status_code, bleg}` - Report rejection with status code

  ## Example

      def handle_reject(response, bleg) do
        {:rejected, response.status, bleg}
      end
  """
  @callback handle_reject(response :: map(), bleg :: BLeg.t()) ::
              {:rejected, non_neg_integer(), BLeg.t()}

  @doc """
  Called when an in-dialog re-INVITE is received from the B-leg.

  ## Arguments

  - `reinvite` - Map containing the re-INVITE request
  - `bleg` - The current B-leg state

  ## Return

  - `{:passthrough, bleg}` - Forward re-INVITE to A-leg as-is
  - `{:modified, reinvite, bleg}` - Forward modified re-INVITE to A-leg

  ## Example

      def handle_reinvite(reinvite, bleg) do
        {:passthrough, bleg}
      end
  """
  @callback handle_reinvite(reinvite :: map(), bleg :: BLeg.t()) ::
              {:passthrough, BLeg.t()} | {:modified, map(), BLeg.t()}

  @doc """
  Called when BYE is received from the B-leg (B-leg hung up).

  ## Arguments

  - `bye` - Map containing the BYE request
  - `bleg` - The current B-leg state

  ## Return

  - `{:hangup, bleg}` - End the call

  ## Example

      def handle_bye(_bye, bleg) do
        {:hangup, bleg}
      end
  """
  @callback handle_bye(bye :: map(), bleg :: BLeg.t()) :: {:hangup, BLeg.t()}

  @doc """
  Provides default implementations and imports helper functions.

  When you `use Parrot.BLegHandler`, you get:

  1. Default implementations of all callbacks
  2. Helper functions: `put_header/3`, `remove_header/2`, `modify_sdp/2`
  3. The `@behaviour Parrot.BLegHandler` annotation

  Override any callback by defining it in your module.
  """
  defmacro __using__(_opts) do
    quote do
      @behaviour Parrot.BLegHandler

      # ---------------------------------------------------------------------------
      # Helper Functions
      # ---------------------------------------------------------------------------

      @doc """
      Adds or updates a header on the INVITE message.

      ## Examples

          invite |> put_header("X-Custom", "value")

      """
      def put_header(%{headers: headers} = invite, header_name, header_value)
          when is_binary(header_name) do
        %{invite | headers: Map.put(headers, header_name, header_value)}
      end

      @doc """
      Removes a header from the INVITE message.

      ## Examples

          invite |> remove_header("X-Internal")

      """
      def remove_header(%{headers: headers} = invite, header_name) when is_binary(header_name) do
        %{invite | headers: Map.delete(headers, header_name)}
      end

      @doc """
      Applies a transformation function to the SDP body.

      ## Examples

          invite |> modify_sdp(fn sdp -> sdp <> "a=custom:value\\r\\n" end)

      """
      def modify_sdp(%{body: body} = invite, transform_fn) when is_function(transform_fn, 1) do
        %{invite | body: transform_fn.(body || "")}
      end

      # ---------------------------------------------------------------------------
      # Default Callback Implementations
      # ---------------------------------------------------------------------------

      @impl Parrot.BLegHandler
      def before_invite(invite, _state) do
        invite
      end

      @impl Parrot.BLegHandler
      def handle_provisional(%{status: 180} = _response, bleg) do
        {:ring, bleg}
      end

      @impl Parrot.BLegHandler
      def handle_provisional(%{status: 183} = _response, bleg) do
        {:early_media, bleg}
      end

      @impl Parrot.BLegHandler
      def handle_provisional(_response, bleg) do
        {:continue, bleg}
      end

      @impl Parrot.BLegHandler
      def handle_answer(_response, bleg) do
        {:connect, bleg}
      end

      @impl Parrot.BLegHandler
      def handle_reject(response, bleg) do
        {:rejected, response.status, bleg}
      end

      @impl Parrot.BLegHandler
      def handle_reinvite(_reinvite, bleg) do
        {:passthrough, bleg}
      end

      @impl Parrot.BLegHandler
      def handle_bye(_bye, bleg) do
        {:hangup, bleg}
      end

      defoverridable before_invite: 2,
                     handle_provisional: 2,
                     handle_answer: 2,
                     handle_reject: 2,
                     handle_reinvite: 2,
                     handle_bye: 2
    end
  end
end
