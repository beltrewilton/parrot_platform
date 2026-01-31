defmodule ParrotMedia.Elements.DirectionGateTest do
  @moduledoc """
  Tests for DirectionGate filter element.

  The DirectionGate controls audio flow based on media direction:
  - :sendrecv - Pass through all buffers (normal operation)
  - :sendonly - Pass through (for send path) or drop (for receive path)
  - :recvonly - Drop (for send path) or pass through (for receive path)
  - :inactive - Drop all buffers

  The gate operates in one of two roles:
  - :send - Controls outbound audio (muted in :recvonly and :inactive)
  - :receive - Controls inbound audio (muted in :sendonly and :inactive)
  """

  use ExUnit.Case, async: true

  alias ParrotMedia.Elements.DirectionGate

  @moduletag :direction_gate

  # ===========================================================================
  # Unit Tests - should_pass?/2 function
  # ===========================================================================

  describe "DirectionGate.should_pass?/2 in send role" do
    test "passes buffers in :sendrecv direction" do
      assert DirectionGate.should_pass?(:send, :sendrecv) == true
    end

    test "passes buffers in :sendonly direction" do
      # :sendonly means we're sending, so send path should pass
      assert DirectionGate.should_pass?(:send, :sendonly) == true
    end

    test "drops buffers in :recvonly direction" do
      # :recvonly means we're only receiving, so send path should be muted
      assert DirectionGate.should_pass?(:send, :recvonly) == false
    end

    test "drops buffers in :inactive direction" do
      # :inactive means all paths muted
      assert DirectionGate.should_pass?(:send, :inactive) == false
    end
  end

  describe "DirectionGate.should_pass?/2 in receive role" do
    test "passes buffers in :sendrecv direction" do
      assert DirectionGate.should_pass?(:receive, :sendrecv) == true
    end

    test "drops buffers in :sendonly direction" do
      # :sendonly means we're only sending, so receive path should be muted
      assert DirectionGate.should_pass?(:receive, :sendonly) == false
    end

    test "passes buffers in :recvonly direction" do
      # :recvonly means we're receiving, so receive path should pass
      assert DirectionGate.should_pass?(:receive, :recvonly) == true
    end

    test "drops buffers in :inactive direction" do
      # :inactive means all paths muted
      assert DirectionGate.should_pass?(:receive, :inactive) == false
    end
  end

  # ===========================================================================
  # Truth Table Verification - Complete coverage
  # ===========================================================================

  describe "DirectionGate truth table" do
    @truth_table [
      # {role, direction, expected_pass?}
      {:send, :sendrecv, true},
      {:send, :sendonly, true},
      {:send, :recvonly, false},
      {:send, :inactive, false},
      {:receive, :sendrecv, true},
      {:receive, :sendonly, false},
      {:receive, :recvonly, true},
      {:receive, :inactive, false}
    ]

    for {role, direction, expected} <- @truth_table do
      test "#{role} role with #{direction} direction returns #{expected}" do
        assert DirectionGate.should_pass?(unquote(role), unquote(direction)) == unquote(expected)
      end
    end
  end
end
