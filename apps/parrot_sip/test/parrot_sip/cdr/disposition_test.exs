defmodule ParrotSip.CDR.DispositionTest do
  @moduledoc """
  Tests for ParrotSip.CDR.Disposition module.

  The Disposition module maps SIP response codes to call outcome atoms
  as specified in the CDR data model.
  """
  use ExUnit.Case, async: true

  alias ParrotSip.CDR.Disposition

  describe "type/0" do
    test "returns all valid disposition atoms" do
      dispositions = Disposition.all()

      assert :answered in dispositions
      assert :busy in dispositions
      assert :no_answer in dispositions
      assert :timeout in dispositions
      assert :cancelled in dispositions
      assert :declined in dispositions
      assert :not_found in dispositions
      assert :forbidden in dispositions
      assert :server_error in dispositions
      assert :failed in dispositions
      assert :redirected in dispositions
      assert :abandoned in dispositions
      assert length(dispositions) == 12
    end
  end

  describe "from_sip_code/2 - answered calls" do
    test "returns :answered for 200 OK when call was answered" do
      assert Disposition.from_sip_code(200, true) == :answered
    end

    test "returns :answered for 200 OK only when was_answered is true" do
      # 200 with was_answered=false is an edge case that shouldn't happen
      # in practice, but we handle it by returning :answered anyway
      # since 200 is success
      assert Disposition.from_sip_code(200, false) == :answered
    end
  end

  describe "from_sip_code/2 - specific 4xx codes" do
    test "returns :busy for 486 Busy Here" do
      assert Disposition.from_sip_code(486, false) == :busy
    end

    test "returns :no_answer for 480 Temporarily Unavailable" do
      assert Disposition.from_sip_code(480, false) == :no_answer
    end

    test "returns :timeout for 408 Request Timeout" do
      assert Disposition.from_sip_code(408, false) == :timeout
    end

    test "returns :cancelled for 487 Request Terminated" do
      assert Disposition.from_sip_code(487, false) == :cancelled
    end
  end

  describe "from_sip_code/2 - 6xx codes" do
    test "returns :declined for 603 Decline" do
      assert Disposition.from_sip_code(603, false) == :declined
    end

    test "returns :not_found for 604 Does Not Exist Anywhere" do
      assert Disposition.from_sip_code(604, false) == :not_found
    end

    test "returns :declined for 600 Busy Everywhere" do
      # 600 is similar to busy but global, treat as declined
      assert Disposition.from_sip_code(600, false) == :declined
    end

    test "returns :declined for other 6xx codes" do
      # 606 Not Acceptable
      assert Disposition.from_sip_code(606, false) == :declined
    end
  end

  describe "from_sip_code/2 - not found codes" do
    test "returns :not_found for 404 Not Found" do
      assert Disposition.from_sip_code(404, false) == :not_found
    end

    test "returns :not_found for 604 Does Not Exist Anywhere" do
      assert Disposition.from_sip_code(604, false) == :not_found
    end
  end

  describe "from_sip_code/2 - forbidden/auth codes" do
    test "returns :forbidden for 403 Forbidden" do
      assert Disposition.from_sip_code(403, false) == :forbidden
    end

    test "returns :forbidden for 401 Unauthorized" do
      assert Disposition.from_sip_code(401, false) == :forbidden
    end

    test "returns :forbidden for 407 Proxy Authentication Required" do
      assert Disposition.from_sip_code(407, false) == :forbidden
    end
  end

  describe "from_sip_code/2 - 3xx redirection" do
    test "returns :redirected for 300 Multiple Choices" do
      assert Disposition.from_sip_code(300, false) == :redirected
    end

    test "returns :redirected for 301 Moved Permanently" do
      assert Disposition.from_sip_code(301, false) == :redirected
    end

    test "returns :redirected for 302 Moved Temporarily" do
      assert Disposition.from_sip_code(302, false) == :redirected
    end

    test "returns :redirected for 305 Use Proxy" do
      assert Disposition.from_sip_code(305, false) == :redirected
    end

    test "returns :redirected for 380 Alternative Service" do
      assert Disposition.from_sip_code(380, false) == :redirected
    end
  end

  describe "from_sip_code/2 - 5xx server errors" do
    test "returns :server_error for 500 Server Internal Error" do
      assert Disposition.from_sip_code(500, false) == :server_error
    end

    test "returns :server_error for 501 Not Implemented" do
      assert Disposition.from_sip_code(501, false) == :server_error
    end

    test "returns :server_error for 502 Bad Gateway" do
      assert Disposition.from_sip_code(502, false) == :server_error
    end

    test "returns :server_error for 503 Service Unavailable" do
      assert Disposition.from_sip_code(503, false) == :server_error
    end

    test "returns :server_error for 504 Server Time-out" do
      assert Disposition.from_sip_code(504, false) == :server_error
    end

    test "returns :server_error for 505 Version Not Supported" do
      assert Disposition.from_sip_code(505, false) == :server_error
    end

    test "returns :server_error for 513 Message Too Large" do
      assert Disposition.from_sip_code(513, false) == :server_error
    end
  end

  describe "from_sip_code/2 - other 4xx errors (failed)" do
    test "returns :failed for 400 Bad Request" do
      assert Disposition.from_sip_code(400, false) == :failed
    end

    test "returns :failed for 402 Payment Required" do
      assert Disposition.from_sip_code(402, false) == :failed
    end

    test "returns :failed for 405 Method Not Allowed" do
      assert Disposition.from_sip_code(405, false) == :failed
    end

    test "returns :failed for 406 Not Acceptable" do
      assert Disposition.from_sip_code(406, false) == :failed
    end

    test "returns :failed for 410 Gone" do
      assert Disposition.from_sip_code(410, false) == :failed
    end

    test "returns :failed for 413 Request Entity Too Large" do
      assert Disposition.from_sip_code(413, false) == :failed
    end

    test "returns :failed for 414 Request-URI Too Long" do
      assert Disposition.from_sip_code(414, false) == :failed
    end

    test "returns :failed for 415 Unsupported Media Type" do
      assert Disposition.from_sip_code(415, false) == :failed
    end

    test "returns :failed for 416 Unsupported URI Scheme" do
      assert Disposition.from_sip_code(416, false) == :failed
    end

    test "returns :failed for 420 Bad Extension" do
      assert Disposition.from_sip_code(420, false) == :failed
    end

    test "returns :failed for 421 Extension Required" do
      assert Disposition.from_sip_code(421, false) == :failed
    end

    test "returns :failed for 423 Interval Too Brief" do
      assert Disposition.from_sip_code(423, false) == :failed
    end

    test "returns :failed for 481 Call/Transaction Does Not Exist" do
      assert Disposition.from_sip_code(481, false) == :failed
    end

    test "returns :failed for 482 Loop Detected" do
      assert Disposition.from_sip_code(482, false) == :failed
    end

    test "returns :failed for 483 Too Many Hops" do
      assert Disposition.from_sip_code(483, false) == :failed
    end

    test "returns :failed for 484 Address Incomplete" do
      assert Disposition.from_sip_code(484, false) == :failed
    end

    test "returns :failed for 485 Ambiguous" do
      assert Disposition.from_sip_code(485, false) == :failed
    end

    test "returns :failed for 488 Not Acceptable Here" do
      assert Disposition.from_sip_code(488, false) == :failed
    end

    test "returns :failed for 491 Request Pending" do
      assert Disposition.from_sip_code(491, false) == :failed
    end

    test "returns :failed for 493 Undecipherable" do
      assert Disposition.from_sip_code(493, false) == :failed
    end
  end

  describe "from_sip_code/2 - edge cases" do
    test "returns :abandoned for nil code" do
      assert Disposition.from_sip_code(nil, false) == :abandoned
    end

    test "returns :abandoned for 0 code" do
      assert Disposition.from_sip_code(0, false) == :abandoned
    end

    test "returns :failed for unknown 4xx code" do
      # 499 is not a standard SIP code
      assert Disposition.from_sip_code(499, false) == :failed
    end

    test "returns :server_error for unknown 5xx code" do
      # 599 is not a standard SIP code
      assert Disposition.from_sip_code(599, false) == :server_error
    end

    test "returns :redirected for unknown 3xx code" do
      # 399 is not a standard SIP code
      assert Disposition.from_sip_code(399, false) == :redirected
    end
  end

  describe "from_sip_code/2 - 2xx success codes" do
    test "returns :answered for any 2xx code" do
      assert Disposition.from_sip_code(200, true) == :answered
      assert Disposition.from_sip_code(202, true) == :answered
    end
  end

  describe "from_sip_code/2 - 1xx provisional responses" do
    test "returns :abandoned for 1xx codes (should not be used for disposition)" do
      # 1xx are provisional and should not be used to determine final disposition
      # If we get 1xx as final, treat as abandoned (no final response received)
      assert Disposition.from_sip_code(100, false) == :abandoned
      assert Disposition.from_sip_code(180, false) == :abandoned
      assert Disposition.from_sip_code(183, false) == :abandoned
    end
  end

  describe "valid?/1" do
    test "returns true for valid disposition atoms" do
      assert Disposition.valid?(:answered) == true
      assert Disposition.valid?(:busy) == true
      assert Disposition.valid?(:no_answer) == true
      assert Disposition.valid?(:timeout) == true
      assert Disposition.valid?(:cancelled) == true
      assert Disposition.valid?(:declined) == true
      assert Disposition.valid?(:not_found) == true
      assert Disposition.valid?(:forbidden) == true
      assert Disposition.valid?(:server_error) == true
      assert Disposition.valid?(:failed) == true
      assert Disposition.valid?(:redirected) == true
      assert Disposition.valid?(:abandoned) == true
    end

    test "returns false for invalid atoms" do
      assert Disposition.valid?(:invalid) == false
      assert Disposition.valid?(:success) == false
      assert Disposition.valid?(:unknown) == false
    end

    test "returns false for non-atoms" do
      assert Disposition.valid?("answered") == false
      assert Disposition.valid?(200) == false
      assert Disposition.valid?(nil) == false
    end
  end

  describe "to_string/1" do
    test "converts disposition atoms to human-readable strings" do
      assert Disposition.to_string(:answered) == "Answered"
      assert Disposition.to_string(:busy) == "Busy"
      assert Disposition.to_string(:no_answer) == "No Answer"
      assert Disposition.to_string(:timeout) == "Timeout"
      assert Disposition.to_string(:cancelled) == "Cancelled"
      assert Disposition.to_string(:declined) == "Declined"
      assert Disposition.to_string(:not_found) == "Not Found"
      assert Disposition.to_string(:forbidden) == "Forbidden"
      assert Disposition.to_string(:server_error) == "Server Error"
      assert Disposition.to_string(:failed) == "Failed"
      assert Disposition.to_string(:redirected) == "Redirected"
      assert Disposition.to_string(:abandoned) == "Abandoned"
    end
  end

  describe "from_string/1" do
    test "parses human-readable strings to disposition atoms" do
      assert Disposition.from_string("Answered") == {:ok, :answered}
      assert Disposition.from_string("Busy") == {:ok, :busy}
      assert Disposition.from_string("No Answer") == {:ok, :no_answer}
      assert Disposition.from_string("Timeout") == {:ok, :timeout}
      assert Disposition.from_string("Cancelled") == {:ok, :cancelled}
      assert Disposition.from_string("Declined") == {:ok, :declined}
      assert Disposition.from_string("Not Found") == {:ok, :not_found}
      assert Disposition.from_string("Forbidden") == {:ok, :forbidden}
      assert Disposition.from_string("Server Error") == {:ok, :server_error}
      assert Disposition.from_string("Failed") == {:ok, :failed}
      assert Disposition.from_string("Redirected") == {:ok, :redirected}
      assert Disposition.from_string("Abandoned") == {:ok, :abandoned}
    end

    test "handles lowercase input" do
      assert Disposition.from_string("answered") == {:ok, :answered}
      assert Disposition.from_string("no answer") == {:ok, :no_answer}
    end

    test "returns error for invalid strings" do
      assert Disposition.from_string("Invalid") == {:error, :invalid_disposition}
      assert Disposition.from_string("") == {:error, :invalid_disposition}
    end
  end
end
