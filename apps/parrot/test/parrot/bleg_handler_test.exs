defmodule Parrot.BLegHandlerTest do
  use ExUnit.Case, async: true

  alias Parrot.BLeg

  describe "behaviour definition" do
    test "defines before_invite/2 callback" do
      callbacks = Parrot.BLegHandler.behaviour_info(:callbacks)
      assert {:before_invite, 2} in callbacks
    end

    test "defines handle_provisional/2 callback" do
      callbacks = Parrot.BLegHandler.behaviour_info(:callbacks)
      assert {:handle_provisional, 2} in callbacks
    end

    test "defines handle_answer/2 callback" do
      callbacks = Parrot.BLegHandler.behaviour_info(:callbacks)
      assert {:handle_answer, 2} in callbacks
    end

    test "defines handle_reject/2 callback" do
      callbacks = Parrot.BLegHandler.behaviour_info(:callbacks)
      assert {:handle_reject, 2} in callbacks
    end

    test "defines handle_reinvite/2 callback" do
      callbacks = Parrot.BLegHandler.behaviour_info(:callbacks)
      assert {:handle_reinvite, 2} in callbacks
    end

    test "defines handle_bye/2 callback" do
      callbacks = Parrot.BLegHandler.behaviour_info(:callbacks)
      assert {:handle_bye, 2} in callbacks
    end

    test "defines all 6 expected callbacks" do
      callbacks = Parrot.BLegHandler.behaviour_info(:callbacks)
      assert length(callbacks) == 6
    end
  end

  describe "use Parrot.BLegHandler" do
    defmodule MinimalHandler do
      use Parrot.BLegHandler
    end

    test "provides default before_invite/2 implementation that returns invite unchanged" do
      invite = %{method: "INVITE", headers: %{}}
      state = %{original_caller: "sip:alice@example.com"}

      result = MinimalHandler.before_invite(invite, state)

      assert result == invite
    end

    test "provides default handle_provisional/2 for 180 Ringing" do
      response = %{status: 180, reason: "Ringing"}
      bleg = BLeg.new()

      assert {:ring, ^bleg} = MinimalHandler.handle_provisional(response, bleg)
    end

    test "provides default handle_provisional/2 for 183 Session Progress" do
      response = %{status: 183, reason: "Session Progress"}
      bleg = BLeg.new()

      assert {:early_media, ^bleg} = MinimalHandler.handle_provisional(response, bleg)
    end

    test "provides default handle_provisional/2 for other provisional responses" do
      response = %{status: 100, reason: "Trying"}
      bleg = BLeg.new()

      assert {:continue, ^bleg} = MinimalHandler.handle_provisional(response, bleg)
    end

    test "provides default handle_answer/2 implementation" do
      response = %{status: 200, reason: "OK"}
      bleg = BLeg.new()

      assert {:connect, ^bleg} = MinimalHandler.handle_answer(response, bleg)
    end

    test "provides default handle_reject/2 implementation" do
      response = %{status: 486, reason: "Busy Here"}
      bleg = BLeg.new()

      assert {:rejected, 486, ^bleg} = MinimalHandler.handle_reject(response, bleg)
    end

    test "provides default handle_reinvite/2 implementation" do
      reinvite = %{method: "INVITE", headers: %{}}
      bleg = BLeg.new()

      assert {:passthrough, ^bleg} = MinimalHandler.handle_reinvite(reinvite, bleg)
    end

    test "provides default handle_bye/2 implementation" do
      bye = %{method: "BYE", headers: %{}}
      bleg = BLeg.new()

      assert {:hangup, ^bleg} = MinimalHandler.handle_bye(bye, bleg)
    end
  end

  describe "helper functions from use macro" do
    defmodule HelperTestHandler do
      use Parrot.BLegHandler
    end

    test "put_header/3 adds a header to the invite" do
      invite = %{headers: %{"Content-Type" => "application/sdp"}}

      result = HelperTestHandler.put_header(invite, "X-Custom", "value")

      assert result.headers["X-Custom"] == "value"
      assert result.headers["Content-Type"] == "application/sdp"
    end

    test "put_header/3 overwrites existing header" do
      invite = %{headers: %{"X-Custom" => "old-value"}}

      result = HelperTestHandler.put_header(invite, "X-Custom", "new-value")

      assert result.headers["X-Custom"] == "new-value"
    end

    test "remove_header/2 removes a header from the invite" do
      invite = %{headers: %{"X-Internal" => "secret", "X-Public" => "visible"}}

      result = HelperTestHandler.remove_header(invite, "X-Internal")

      refute Map.has_key?(result.headers, "X-Internal")
      assert result.headers["X-Public"] == "visible"
    end

    test "remove_header/2 handles non-existent header gracefully" do
      invite = %{headers: %{"X-Public" => "visible"}}

      result = HelperTestHandler.remove_header(invite, "X-NonExistent")

      assert result == invite
    end

    test "modify_sdp/2 applies transformation function to SDP body" do
      invite = %{body: "v=0\r\no=- 123 456 IN IP4 127.0.0.1\r\n", headers: %{}}

      transform = fn sdp -> sdp <> "a=custom:attribute\r\n" end
      result = HelperTestHandler.modify_sdp(invite, transform)

      assert result.body == "v=0\r\no=- 123 456 IN IP4 127.0.0.1\r\na=custom:attribute\r\n"
    end

    test "modify_sdp/2 handles nil body" do
      invite = %{body: nil, headers: %{}}

      transform = fn sdp -> sdp <> "extra" end
      result = HelperTestHandler.modify_sdp(invite, transform)

      # nil body stays nil or becomes what the transform returns
      assert result.body == "extra"
    end
  end

  describe "overriding callbacks" do
    defmodule CustomBLegHandler do
      use Parrot.BLegHandler

      def before_invite(invite, state) do
        invite
        |> put_header("X-Original-Caller", state.original_caller)
        |> put_header("X-Custom", "value")
        |> remove_header("X-Internal")
      end

      def handle_provisional(%{status: 180} = _response, bleg) do
        # Custom handling for 180 Ringing
        {:ring, %{bleg | assigns: Map.put(bleg.assigns, :ringing, true)}}
      end

      def handle_provisional(%{status: 183} = _response, bleg) do
        # Custom handling for 183 Session Progress with early media
        {:early_media, %{bleg | assigns: Map.put(bleg.assigns, :early_media, true)}}
      end

      def handle_provisional(_response, bleg) do
        {:continue, bleg}
      end

      def handle_answer(_response, bleg) do
        {:connect,
         %{bleg | assigns: Map.put(bleg.assigns, :answered_at, :erlang.system_time(:second))}}
      end

      def handle_reject(response, bleg) do
        {:rejected, response.status,
         %{bleg | assigns: Map.put(bleg.assigns, :reject_reason, response.reason)}}
      end
    end

    test "before_invite adds custom headers" do
      invite = %{headers: %{"X-Internal" => "to-remove"}}
      state = %{original_caller: "sip:alice@example.com"}

      result = CustomBLegHandler.before_invite(invite, state)

      assert result.headers["X-Original-Caller"] == "sip:alice@example.com"
      assert result.headers["X-Custom"] == "value"
      refute Map.has_key?(result.headers, "X-Internal")
    end

    test "handle_provisional tracks ringing state for 180" do
      response = %{status: 180, reason: "Ringing"}
      bleg = BLeg.new()

      {:ring, result} = CustomBLegHandler.handle_provisional(response, bleg)

      assert result.assigns.ringing == true
    end

    test "handle_provisional tracks early media for 183" do
      response = %{status: 183, reason: "Session Progress"}
      bleg = BLeg.new()

      {:early_media, result} = CustomBLegHandler.handle_provisional(response, bleg)

      assert result.assigns.early_media == true
    end

    test "handle_answer tracks answered timestamp" do
      response = %{status: 200, reason: "OK"}
      bleg = BLeg.new()

      {:connect, result} = CustomBLegHandler.handle_answer(response, bleg)

      assert is_integer(result.assigns.answered_at)
    end

    test "handle_reject captures rejection reason" do
      response = %{status: 486, reason: "Busy Here"}
      bleg = BLeg.new()

      {:rejected, status, result} = CustomBLegHandler.handle_reject(response, bleg)

      assert status == 486
      assert result.assigns.reject_reason == "Busy Here"
    end
  end

  describe "complex before_invite manipulation" do
    defmodule ComplexManipulationHandler do
      use Parrot.BLegHandler

      def before_invite(invite, state) do
        invite
        |> put_header("X-Original-Caller", state.original_caller)
        |> put_header("P-Asserted-Identity", state.pai)
        |> remove_header("X-Private-Data")
        |> modify_sdp(&add_custom_attribute/1)
      end

      defp add_custom_attribute(sdp) when is_binary(sdp) do
        sdp <> "a=X-custom:bridged-call\r\n"
      end

      defp add_custom_attribute(nil), do: nil
    end

    test "performs complex invite manipulation with headers and SDP" do
      invite = %{
        headers: %{
          "X-Private-Data" => "secret",
          "From" => "sip:alice@example.com"
        },
        body: "v=0\r\no=- 123 456 IN IP4 127.0.0.1\r\n"
      }

      state = %{
        original_caller: "sip:original@caller.com",
        pai: "<sip:real@identity.com>"
      }

      result = ComplexManipulationHandler.before_invite(invite, state)

      # Headers manipulated correctly
      assert result.headers["X-Original-Caller"] == "sip:original@caller.com"
      assert result.headers["P-Asserted-Identity"] == "<sip:real@identity.com>"
      refute Map.has_key?(result.headers, "X-Private-Data")
      assert result.headers["From"] == "sip:alice@example.com"

      # SDP modified
      assert String.contains?(result.body, "a=X-custom:bridged-call")
    end
  end

  describe "BLeg struct" do
    test "new/0 creates a BLeg with defaults" do
      bleg = BLeg.new()

      assert bleg.id != nil
      assert bleg.destination == nil
      assert bleg.state == :init
      assert bleg.assigns == %{}
    end

    test "new/1 accepts options" do
      bleg =
        BLeg.new(
          destination: "sip:bob@example.com",
          state: :ringing,
          assigns: %{custom: "value"}
        )

      assert bleg.destination == "sip:bob@example.com"
      assert bleg.state == :ringing
      assert bleg.assigns.custom == "value"
    end

    test "assign/3 updates assigns" do
      bleg = BLeg.new()

      updated = BLeg.assign(bleg, :key, "value")

      assert updated.assigns.key == "value"
    end
  end
end
