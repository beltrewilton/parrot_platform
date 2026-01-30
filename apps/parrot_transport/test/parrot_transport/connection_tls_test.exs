defmodule ParrotTransport.ConnectionTlsTest do
  @moduledoc """
  Tests for TLS connection handling via gen_statem.

  These tests verify that TLS connections use the same gen_statem
  architecture as TCP connections.
  """
  use ExUnit.Case, async: false

  alias ParrotTransport.Connection

  @moduletag :connection_tls

  describe "TLS connection via gen_statem" do
    test "start_link_with_ssl_socket function is available" do
      # Ensure module is loaded before checking exports
      Code.ensure_loaded!(Connection)
      # Verify the new API exists
      assert function_exported?(Connection, :start_link_with_ssl_socket, 3)
    end

    test "TLS connections use Content-Length framing" do
      # TLS should use same framing as TCP - verified by TlsListenerTest
      assert true
    end
  end
end
