defmodule ParrotSip.CDR.TerminationCauseTest do
  use ExUnit.Case, async: true

  alias ParrotSip.CDR.TerminationCause

  @moduletag :cdr

  describe "struct creation" do
    test "creates struct with all fields" do
      cause = %TerminationCause{
        party: :caller,
        sip_code: 200,
        reason: "BYE",
        method: :bye
      }

      assert cause.party == :caller
      assert cause.sip_code == 200
      assert cause.reason == "BYE"
      assert cause.method == :bye
    end

    test "all fields default to nil" do
      cause = %TerminationCause{}

      assert cause.party == nil
      assert cause.sip_code == nil
      assert cause.reason == nil
      assert cause.method == nil
    end

    test "allows partial field assignment" do
      cause = %TerminationCause{
        party: :system,
        sip_code: 500
      }

      assert cause.party == :system
      assert cause.sip_code == 500
      assert cause.reason == nil
      assert cause.method == nil
    end
  end

  describe "party field" do
    test "accepts :caller value" do
      cause = %TerminationCause{party: :caller}
      assert cause.party == :caller
    end

    test "accepts :callee value" do
      cause = %TerminationCause{party: :callee}
      assert cause.party == :callee
    end

    test "accepts :system value" do
      cause = %TerminationCause{party: :system}
      assert cause.party == :system
    end
  end

  describe "method field" do
    test "accepts :bye value" do
      cause = %TerminationCause{method: :bye}
      assert cause.method == :bye
    end

    test "accepts :cancel value" do
      cause = %TerminationCause{method: :cancel}
      assert cause.method == :cancel
    end

    test "accepts :error value" do
      cause = %TerminationCause{method: :error}
      assert cause.method == :error
    end

    test "accepts nil value" do
      cause = %TerminationCause{method: nil}
      assert cause.method == nil
    end
  end

  describe "typical termination scenarios" do
    test "BYE from caller" do
      cause = %TerminationCause{
        party: :caller,
        sip_code: 200,
        reason: "BYE",
        method: :bye
      }

      assert cause.party == :caller
      assert cause.sip_code == 200
      assert cause.reason == "BYE"
      assert cause.method == :bye
    end

    test "BYE from callee" do
      cause = %TerminationCause{
        party: :callee,
        sip_code: 200,
        reason: "BYE",
        method: :bye
      }

      assert cause.party == :callee
      assert cause.sip_code == 200
      assert cause.reason == "BYE"
      assert cause.method == :bye
    end

    test "CANCEL from caller" do
      cause = %TerminationCause{
        party: :caller,
        sip_code: 487,
        reason: "Request Terminated",
        method: :cancel
      }

      assert cause.party == :caller
      assert cause.sip_code == 487
      assert cause.reason == "Request Terminated"
      assert cause.method == :cancel
    end

    test "486 Busy Here from callee" do
      cause = %TerminationCause{
        party: :callee,
        sip_code: 486,
        reason: "Busy Here",
        method: nil
      }

      assert cause.party == :callee
      assert cause.sip_code == 486
      assert cause.reason == "Busy Here"
      assert cause.method == nil
    end

    test "480 Temporarily Unavailable" do
      cause = %TerminationCause{
        party: :callee,
        sip_code: 480,
        reason: "Temporarily Unavailable",
        method: nil
      }

      assert cause.party == :callee
      assert cause.sip_code == 480
      assert cause.reason == "Temporarily Unavailable"
      assert cause.method == nil
    end

    test "408 Request Timeout" do
      cause = %TerminationCause{
        party: :system,
        sip_code: 408,
        reason: "Request Timeout",
        method: nil
      }

      assert cause.party == :system
      assert cause.sip_code == 408
      assert cause.reason == "Request Timeout"
      assert cause.method == nil
    end

    test "500 Internal Server Error" do
      cause = %TerminationCause{
        party: :system,
        sip_code: 500,
        reason: "Internal Server Error",
        method: :error
      }

      assert cause.party == :system
      assert cause.sip_code == 500
      assert cause.reason == "Internal Server Error"
      assert cause.method == :error
    end

    test "503 Service Unavailable" do
      cause = %TerminationCause{
        party: :system,
        sip_code: 503,
        reason: "Service Unavailable",
        method: :error
      }

      assert cause.party == :system
      assert cause.sip_code == 503
      assert cause.reason == "Service Unavailable"
      assert cause.method == :error
    end

    test "603 Decline from callee" do
      cause = %TerminationCause{
        party: :callee,
        sip_code: 603,
        reason: "Decline",
        method: nil
      }

      assert cause.party == :callee
      assert cause.sip_code == 603
      assert cause.reason == "Decline"
      assert cause.method == nil
    end

    test "404 Not Found" do
      cause = %TerminationCause{
        party: :system,
        sip_code: 404,
        reason: "Not Found",
        method: nil
      }

      assert cause.party == :system
      assert cause.sip_code == 404
      assert cause.reason == "Not Found"
      assert cause.method == nil
    end

    test "403 Forbidden" do
      cause = %TerminationCause{
        party: :system,
        sip_code: 403,
        reason: "Forbidden",
        method: nil
      }

      assert cause.party == :system
      assert cause.sip_code == 403
      assert cause.reason == "Forbidden"
      assert cause.method == nil
    end
  end

  describe "struct updates" do
    test "updates fields using struct syntax" do
      cause = %TerminationCause{
        party: :caller,
        sip_code: 200,
        reason: "OK",
        method: :bye
      }

      updated = %{cause | reason: "BYE Received"}

      assert updated.reason == "BYE Received"
      assert updated.party == :caller
      assert updated.sip_code == 200
      assert updated.method == :bye
    end
  end

  describe "pattern matching" do
    test "matches on party field" do
      cause = %TerminationCause{
        party: :caller,
        sip_code: 200,
        reason: "BYE",
        method: :bye
      }

      assert %TerminationCause{party: :caller} = cause
    end

    test "matches on method field" do
      cause = %TerminationCause{
        party: :caller,
        sip_code: 487,
        reason: "Request Terminated",
        method: :cancel
      }

      assert %TerminationCause{method: :cancel} = cause
    end

    test "matches on multiple fields" do
      cause = %TerminationCause{
        party: :system,
        sip_code: 500,
        reason: "Internal Server Error",
        method: :error
      }

      assert %TerminationCause{party: :system, method: :error} = cause
    end

    test "extracts fields via pattern matching" do
      cause = %TerminationCause{
        party: :callee,
        sip_code: 486,
        reason: "Busy Here",
        method: nil
      }

      %TerminationCause{party: party, sip_code: code} = cause

      assert party == :callee
      assert code == 486
    end
  end
end
