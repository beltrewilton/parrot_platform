defmodule Parrot.LegTest do
  use ExUnit.Case, async: true

  alias Parrot.Leg

  describe "new/1" do
    test "creates a leg with defaults" do
      leg = Leg.new()

      assert is_binary(leg.id)
      assert String.starts_with?(leg.id, "leg-")
      assert leg.state == :init
      assert leg.direction == nil
      assert leg.dialog_id == nil
      assert leg.media_pid == nil
      assert leg.remote_uri == nil
      assert leg.local_uri == nil
      assert leg.sdp == nil
      assert leg.metadata == %{}
      assert %DateTime{} = leg.created_at
      assert leg.answered_at == nil
    end

    test "creates a leg with custom id" do
      leg = Leg.new(id: "custom-leg-id")

      assert leg.id == "custom-leg-id"
    end

    test "creates an inbound leg" do
      leg = Leg.new(direction: :inbound, remote_uri: "sip:alice@example.com")

      assert leg.direction == :inbound
      assert leg.remote_uri == "sip:alice@example.com"
    end

    test "creates an outbound leg" do
      leg = Leg.new(direction: :outbound, remote_uri: "sip:bob@example.com")

      assert leg.direction == :outbound
      assert leg.remote_uri == "sip:bob@example.com"
    end

    test "creates a leg with all fields" do
      leg =
        Leg.new(
          id: "test-leg",
          direction: :outbound,
          state: :trying,
          dialog_id: "dialog-123",
          media_pid: self(),
          remote_uri: "sip:bob@example.com",
          local_uri: "sip:alice@example.com",
          sdp: "v=0\r\n...",
          metadata: %{custom: "data"}
        )

      assert leg.id == "test-leg"
      assert leg.direction == :outbound
      assert leg.state == :trying
      assert leg.dialog_id == "dialog-123"
      assert leg.media_pid == self()
      assert leg.remote_uri == "sip:bob@example.com"
      assert leg.local_uri == "sip:alice@example.com"
      assert leg.sdp == "v=0\r\n..."
      assert leg.metadata == %{custom: "data"}
    end
  end

  describe "generate_id/0" do
    test "generates unique IDs" do
      id1 = Leg.generate_id()
      id2 = Leg.generate_id()

      assert is_binary(id1)
      assert is_binary(id2)
      assert id1 != id2
      assert String.starts_with?(id1, "leg-")
      assert String.starts_with?(id2, "leg-")
    end
  end

  describe "assign/3" do
    test "assigns key-value to metadata" do
      leg = Leg.new()
      leg = Leg.assign(leg, :custom_key, "value")

      assert leg.metadata[:custom_key] == "value"
    end

    test "overwrites existing keys" do
      leg =
        Leg.new()
        |> Leg.assign(:key, "first")
        |> Leg.assign(:key, "second")

      assert leg.metadata[:key] == "second"
    end

    test "supports multiple assigns via pipe" do
      leg =
        Leg.new()
        |> Leg.assign(:priority, :high)
        |> Leg.assign(:caller_id, "12345")
        |> Leg.assign(:department, "sales")

      assert leg.metadata[:priority] == :high
      assert leg.metadata[:caller_id] == "12345"
      assert leg.metadata[:department] == "sales"
    end
  end

  describe "state transitions" do
    test "init -> trying is valid" do
      leg = Leg.new(state: :init)
      assert {:ok, leg} = Leg.transition(leg, :trying)
      assert leg.state == :trying
    end

    test "trying -> ringing is valid" do
      leg = Leg.new(state: :trying)
      assert {:ok, leg} = Leg.transition(leg, :ringing)
      assert leg.state == :ringing
    end

    test "trying -> early_media is valid" do
      leg = Leg.new(state: :trying)
      assert {:ok, leg} = Leg.transition(leg, :early_media)
      assert leg.state == :early_media
    end

    test "trying -> answered is valid" do
      leg = Leg.new(state: :trying)
      assert {:ok, leg} = Leg.transition(leg, :answered)
      assert leg.state == :answered
      assert %DateTime{} = leg.answered_at
    end

    test "ringing -> early_media is valid" do
      leg = Leg.new(state: :ringing)
      assert {:ok, leg} = Leg.transition(leg, :early_media)
      assert leg.state == :early_media
    end

    test "ringing -> answered is valid" do
      leg = Leg.new(state: :ringing)
      assert {:ok, leg} = Leg.transition(leg, :answered)
      assert leg.state == :answered
      assert %DateTime{} = leg.answered_at
    end

    test "early_media -> answered is valid" do
      leg = Leg.new(state: :early_media)
      assert {:ok, leg} = Leg.transition(leg, :answered)
      assert leg.state == :answered
      assert %DateTime{} = leg.answered_at
    end

    test "answered -> held is valid" do
      leg = Leg.new(state: :answered)
      {:ok, leg} = Leg.transition(leg, :answered)
      assert {:ok, leg} = Leg.transition(leg, :held)
      assert leg.state == :held
    end

    test "held -> answered (resume) is valid" do
      leg = Leg.new(state: :answered)
      {:ok, leg} = Leg.transition(leg, :answered)
      {:ok, leg} = Leg.transition(leg, :held)
      assert {:ok, leg} = Leg.transition(leg, :answered)
      assert leg.state == :answered
    end

    test "any state -> terminated is valid" do
      for initial_state <- [:init, :trying, :ringing, :early_media, :answered, :held] do
        leg = Leg.new(state: initial_state)
        assert {:ok, leg} = Leg.transition(leg, :terminated)
        assert leg.state == :terminated
      end
    end

    test "init -> ringing is invalid" do
      leg = Leg.new(state: :init)
      assert {:error, :invalid_transition} = Leg.transition(leg, :ringing)
      assert leg.state == :init
    end

    test "init -> answered is invalid" do
      leg = Leg.new(state: :init)
      assert {:error, :invalid_transition} = Leg.transition(leg, :answered)
      assert leg.state == :init
    end

    test "init -> held is invalid" do
      leg = Leg.new(state: :init)
      assert {:error, :invalid_transition} = Leg.transition(leg, :held)
      assert leg.state == :init
    end

    test "ringing -> trying is invalid (no backwards)" do
      leg = Leg.new(state: :ringing)
      assert {:error, :invalid_transition} = Leg.transition(leg, :trying)
      assert leg.state == :ringing
    end

    test "terminated -> any state is invalid" do
      for target_state <- [:init, :trying, :ringing, :early_media, :answered, :held] do
        leg = Leg.new(state: :terminated)
        assert {:error, :invalid_transition} = Leg.transition(leg, target_state)
        assert leg.state == :terminated
      end
    end

    test "held -> ringing is invalid" do
      leg = Leg.new(state: :held)
      assert {:error, :invalid_transition} = Leg.transition(leg, :ringing)
      assert leg.state == :held
    end

    test "early_media -> trying is invalid (no backwards)" do
      leg = Leg.new(state: :early_media)
      assert {:error, :invalid_transition} = Leg.transition(leg, :trying)
      assert leg.state == :early_media
    end

    test "early_media -> ringing is invalid (no backwards)" do
      leg = Leg.new(state: :early_media)
      assert {:error, :invalid_transition} = Leg.transition(leg, :ringing)
      assert leg.state == :early_media
    end

    test "answered -> ringing is invalid (no backwards)" do
      leg = Leg.new(state: :answered)
      assert {:error, :invalid_transition} = Leg.transition(leg, :ringing)
      assert leg.state == :answered
    end

    test "answered -> init is invalid (no backwards)" do
      leg = Leg.new(state: :answered)
      assert {:error, :invalid_transition} = Leg.transition(leg, :init)
      assert leg.state == :answered
    end
  end

  describe "transition!/2" do
    test "returns leg on valid transition" do
      leg = Leg.new(state: :init)
      result = Leg.transition!(leg, :trying)
      assert result.state == :trying
    end

    test "raises on invalid transition" do
      leg = Leg.new(state: :init)

      assert_raise Parrot.Leg.InvalidTransitionError, fn ->
        Leg.transition!(leg, :answered)
      end
    end

    test "raised exception contains correct information" do
      leg = Leg.new(id: "test-leg-123", state: :init)

      error =
        assert_raise Parrot.Leg.InvalidTransitionError, fn ->
          Leg.transition!(leg, :answered)
        end

      assert error.from_state == :init
      assert error.to_state == :answered
      assert error.leg_id == "test-leg-123"
      assert Exception.message(error) =~ "init"
      assert Exception.message(error) =~ "answered"
      assert Exception.message(error) =~ "test-leg-123"
    end
  end

  describe "can_transition?/2" do
    test "returns true for valid transitions" do
      leg = Leg.new(state: :init)
      assert Leg.can_transition?(leg, :trying) == true
      assert Leg.can_transition?(leg, :terminated) == true
    end

    test "returns false for invalid transitions" do
      leg = Leg.new(state: :init)
      assert Leg.can_transition?(leg, :ringing) == false
      assert Leg.can_transition?(leg, :answered) == false
      assert Leg.can_transition?(leg, :held) == false
    end
  end

  describe "state predicates" do
    test "init?/1" do
      assert Leg.init?(Leg.new(state: :init))
      refute Leg.init?(Leg.new(state: :trying))
    end

    test "trying?/1" do
      assert Leg.trying?(Leg.new(state: :trying))
      refute Leg.trying?(Leg.new(state: :init))
    end

    test "ringing?/1" do
      assert Leg.ringing?(Leg.new(state: :ringing))
      refute Leg.ringing?(Leg.new(state: :trying))
    end

    test "early_media?/1" do
      assert Leg.early_media?(Leg.new(state: :early_media))
      refute Leg.early_media?(Leg.new(state: :ringing))
    end

    test "answered?/1" do
      assert Leg.answered?(Leg.new(state: :answered))
      refute Leg.answered?(Leg.new(state: :trying))
    end

    test "held?/1" do
      assert Leg.held?(Leg.new(state: :held))
      refute Leg.held?(Leg.new(state: :answered))
    end

    test "terminated?/1" do
      assert Leg.terminated?(Leg.new(state: :terminated))
      refute Leg.terminated?(Leg.new(state: :answered))
    end
  end

  describe "direction predicates" do
    test "inbound?/1" do
      assert Leg.inbound?(Leg.new(direction: :inbound))
      refute Leg.inbound?(Leg.new(direction: :outbound))
      refute Leg.inbound?(Leg.new())
    end

    test "outbound?/1" do
      assert Leg.outbound?(Leg.new(direction: :outbound))
      refute Leg.outbound?(Leg.new(direction: :inbound))
      refute Leg.outbound?(Leg.new())
    end
  end

  describe "set_dialog_id/2" do
    test "sets the dialog_id" do
      leg = Leg.new()
      leg = Leg.set_dialog_id(leg, "dialog-abc-123")

      assert leg.dialog_id == "dialog-abc-123"
    end
  end

  describe "set_media_pid/2" do
    test "sets the media_pid" do
      leg = Leg.new()
      media_pid = self()
      leg = Leg.set_media_pid(leg, media_pid)

      assert leg.media_pid == media_pid
    end
  end

  describe "set_sdp/2" do
    test "sets the SDP" do
      leg = Leg.new()
      sdp = "v=0\r\no=- 123 456 IN IP4 192.168.1.1\r\n"
      leg = Leg.set_sdp(leg, sdp)

      assert leg.sdp == sdp
    end
  end

  describe "active?/1" do
    test "returns true for non-terminal states" do
      assert Leg.active?(Leg.new(state: :init))
      assert Leg.active?(Leg.new(state: :trying))
      assert Leg.active?(Leg.new(state: :ringing))
      assert Leg.active?(Leg.new(state: :early_media))
      assert Leg.active?(Leg.new(state: :answered))
      assert Leg.active?(Leg.new(state: :held))
    end

    test "returns false for terminated state" do
      refute Leg.active?(Leg.new(state: :terminated))
    end
  end

  describe "connected?/1" do
    test "returns true for answered state" do
      assert Leg.connected?(Leg.new(state: :answered))
    end

    test "returns true for held state" do
      assert Leg.connected?(Leg.new(state: :held))
    end

    test "returns false for non-connected states" do
      refute Leg.connected?(Leg.new(state: :init))
      refute Leg.connected?(Leg.new(state: :trying))
      refute Leg.connected?(Leg.new(state: :ringing))
      refute Leg.connected?(Leg.new(state: :early_media))
      refute Leg.connected?(Leg.new(state: :terminated))
    end
  end

  describe "duration/1" do
    test "returns nil when not answered" do
      leg = Leg.new(state: :trying)
      assert Leg.duration(leg) == nil
    end

    test "returns duration in seconds when answered" do
      now = DateTime.utc_now()
      answered_at = DateTime.add(now, -60, :second)

      leg = %Leg{
        Leg.new(state: :answered)
        | answered_at: answered_at
      }

      duration = Leg.duration(leg)
      # Allow some tolerance for test execution time
      assert duration >= 59 and duration <= 61
    end

    test "returns duration for terminated leg that was answered" do
      now = DateTime.utc_now()
      answered_at = DateTime.add(now, -120, :second)

      leg = %Leg{
        Leg.new(state: :terminated)
        | answered_at: answered_at
      }

      duration = Leg.duration(leg)
      assert duration >= 119 and duration <= 121
    end
  end
end
