defmodule SippTest.TransportHelper do
  @moduledoc """
  Helper module for setting up and managing ParrotTransport listeners in tests.

  Provides convenient functions for starting listeners on random ports,
  discovering their addresses, and managing their lifecycle during testing.

  ## Usage

      # Start a UDP listener with handler
      {:ok, listener, port} = TransportHelper.start_udp_listener(handler_pid)

      # Start a TCP listener
      {:ok, listener, port} = TransportHelper.start_tcp_listener(handler_pid)

      # Start a TLS listener with custom certs
      {:ok, listener, port} = TransportHelper.start_tls_listener(
        handler_pid,
        certfile: "test/sipp/fixtures/certs/server-cert.pem",
        keyfile: "test/sipp/fixtures/certs/server-key.pem"
      )

      # Start a WebSocket listener
      {:ok, listener, port} = TransportHelper.start_websocket_listener(handler_pid)

      # Cleanup when done
      :ok = TransportHelper.stop_listener(listener, :tcp)
  """

  alias ParrotTransport.Types.ListenerConfig

  @default_tls_cert "test/sipp/fixtures/certs/server-cert.pem"
  @default_tls_key "test/sipp/fixtures/certs/server-key.pem"
  @default_tls_ca "test/sipp/fixtures/certs/ca-cert.pem"

  @doc """
  Starts a UDP listener on a random port.

  ## Parameters

    * `handler_pid` - Process to receive incoming packets (optional for UDP)
    * `opts` - Optional configuration:
      - `:ip` - IP address to bind to (default: {127, 0, 0, 1})
      - `:port` - Specific port to bind to (default: 0 for random)

  ## Returns

    * `{:ok, listener_pid, port}` - Listener started successfully
    * `{:error, reason}` - Failed to start listener

  ## Examples

      {:ok, listener, port} = start_udp_listener()
      {:ok, listener, port} = start_udp_listener(self())
      {:ok, listener, 5060} = start_udp_listener(self(), port: 5060)
  """
  @spec start_udp_listener(pid() | nil, keyword()) ::
          {:ok, pid(), :inet.port_number()} | {:error, term()}
  def start_udp_listener(handler_pid \\ nil, opts \\ []) do
    ip = Keyword.get(opts, :ip, {127, 0, 0, 1})
    port = Keyword.get(opts, :port, 0)

    config = %ListenerConfig{
      transport: :udp,
      ip: ip,
      port: port
    }

    case ParrotTransport.start_listener(config) do
      {:ok, listener_pid} ->
        # Register handler if provided
        if handler_pid do
          :ok = ParrotTransport.register_handler(listener_pid, handler_pid)
        end

        # Get the actual bound port
        {:ok, {_ip, actual_port}} = ParrotTransport.get_local_address(listener_pid)
        {:ok, listener_pid, actual_port}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Starts a TCP listener on a random port.

  ## Parameters

    * `handler_pid` - Process to receive incoming packets (required for TCP)
    * `opts` - Optional configuration:
      - `:ip` - IP address to bind to (default: {127, 0, 0, 1})
      - `:port` - Specific port to bind to (default: 0 for random)

  ## Returns

    * `{:ok, listener_pid, port}` - Listener started successfully
    * `{:error, reason}` - Failed to start listener

  ## Examples

      {:ok, listener, port} = start_tcp_listener(self())
      {:ok, listener, 5060} = start_tcp_listener(self(), port: 5060)
  """
  @spec start_tcp_listener(pid(), keyword()) ::
          {:ok, pid(), :inet.port_number()} | {:error, term()}
  def start_tcp_listener(handler_pid, opts \\ []) do
    ip = Keyword.get(opts, :ip, {127, 0, 0, 1})
    port = Keyword.get(opts, :port, 0)

    config = %ListenerConfig{
      transport: :tcp,
      ip: ip,
      port: port
    }

    case ParrotTransport.start_tcp_listener(config, handler_pid) do
      {:ok, listener_pid} ->
        # Get the actual bound port
        {:ok, {_ip, actual_port}} = ParrotTransport.TcpListener.get_local_address(listener_pid)
        {:ok, listener_pid, actual_port}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Starts a TLS listener on a random port.

  ## Parameters

    * `handler_pid` - Process to receive incoming packets (required for TLS)
    * `opts` - Optional configuration:
      - `:ip` - IP address to bind to (default: {127, 0, 0, 1})
      - `:port` - Specific port to bind to (default: 0 for random)
      - `:certfile` - Path to server certificate (default: test fixtures)
      - `:keyfile` - Path to server private key (default: test fixtures)
      - `:cacertfile` - Path to CA certificate (default: test fixtures)

  ## Returns

    * `{:ok, listener_pid, port}` - Listener started successfully
    * `{:error, reason}` - Failed to start listener

  ## Examples

      {:ok, listener, port} = start_tls_listener(self())
      {:ok, listener, 5061} = start_tls_listener(self(), port: 5061)
      {:ok, listener, port} = start_tls_listener(self(),
        certfile: "path/to/cert.pem",
        keyfile: "path/to/key.pem"
      )
  """
  @spec start_tls_listener(pid(), keyword()) ::
          {:ok, pid(), :inet.port_number()} | {:error, term()}
  def start_tls_listener(handler_pid, opts \\ []) do
    ip = Keyword.get(opts, :ip, {127, 0, 0, 1})
    port = Keyword.get(opts, :port, 0)
    certfile = Keyword.get(opts, :certfile, @default_tls_cert)
    keyfile = Keyword.get(opts, :keyfile, @default_tls_key)
    cacertfile = Keyword.get(opts, :cacertfile, @default_tls_ca)

    config = %ListenerConfig{
      transport: :tls,
      ip: ip,
      port: port,
      certfile: certfile,
      keyfile: keyfile,
      cacertfile: cacertfile
    }

    case ParrotTransport.start_tls_listener(config, handler_pid) do
      {:ok, listener_pid} ->
        # Get the actual bound port
        {:ok, {_ip, actual_port}} = ParrotTransport.TlsListener.get_local_address(listener_pid)
        {:ok, listener_pid, actual_port}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Starts a WebSocket listener on a random port.

  ## Parameters

    * `handler_pid` - Process to receive incoming packets (required for WebSocket)
    * `opts` - Optional configuration:
      - `:ip` - IP address to bind to (default: {127, 0, 0, 1})
      - `:port` - Specific port to bind to (default: 0 for random)

  ## Returns

    * `{:ok, listener_pid, port}` - Listener started successfully
    * `{:error, reason}` - Failed to start listener

  ## Examples

      {:ok, listener, port} = start_websocket_listener(self())
      {:ok, listener, 8080} = start_websocket_listener(self(), port: 8080)
  """
  @spec start_websocket_listener(pid(), keyword()) ::
          {:ok, pid(), :inet.port_number()} | {:error, term()}
  def start_websocket_listener(handler_pid, opts \\ []) do
    ip = Keyword.get(opts, :ip, {127, 0, 0, 1})
    port = Keyword.get(opts, :port, 0)

    config = %ListenerConfig{
      transport: :websocket,
      ip: ip,
      port: port
    }

    case ParrotTransport.start_websocket_listener(config, handler_pid) do
      {:ok, listener_pid} ->
        # Get the actual bound port
        {:ok, {_ip, actual_port}} =
          ParrotTransport.WebsocketListener.get_local_address(listener_pid)

        {:ok, listener_pid, actual_port}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Stops a listener gracefully.

  ## Parameters

    * `listener_pid` - The listener process to stop
    * `transport` - Transport type: :udp, :tcp, :tls, or :websocket

  ## Returns

    * `:ok`

  ## Examples

      :ok = stop_listener(listener, :udp)
      :ok = stop_listener(listener, :tcp)
  """
  @spec stop_listener(pid(), :udp | :tcp | :tls | :websocket) :: :ok
  def stop_listener(listener_pid, transport) do
    case transport do
      :udp ->
        ParrotTransport.UdpListener.stop(listener_pid)

      :tcp ->
        ParrotTransport.TcpListener.stop(listener_pid)

      :tls ->
        ParrotTransport.TlsListener.stop(listener_pid)

      :websocket ->
        ParrotTransport.WebsocketListener.stop(listener_pid)
    end
  end

  @doc """
  Waits for a listener to be ready to accept connections.

  This is useful for ensuring a listener is fully initialized before
  running tests against it.

  ## Parameters

    * `listener_pid` - The listener process
    * `timeout` - Maximum time to wait in milliseconds (default: 1000)

  ## Returns

    * `:ok` - Listener is ready
    * `{:error, :timeout}` - Timed out waiting for listener

  ## Examples

      {:ok, listener, _port} = start_tcp_listener(self())
      :ok = wait_for_listener(listener)
  """
  @spec wait_for_listener(pid(), timeout()) :: :ok | {:error, :timeout}
  def wait_for_listener(listener_pid, timeout \\ 1000) do
    end_time = System.monotonic_time(:millisecond) + timeout

    wait_loop(listener_pid, end_time)
  end

  @doc """
  Generates a unique log directory for a test.

  Creates a directory under test/sipp/logs/ with a timestamp and optional
  test name suffix.

  ## Parameters

    * `test_name` - Optional test name to include in directory name

  ## Returns

    * `String.t()` - Path to log directory

  ## Examples

      log_dir = generate_log_dir("invite_test")
      # => "test/sipp/logs/20230615_123456_invite_test"
  """
  @spec generate_log_dir(String.t() | nil) :: String.t()
  def generate_log_dir(test_name \\ nil) do
    timestamp =
      DateTime.utc_now()
      |> DateTime.to_unix()
      |> to_string()

    suffix = if test_name, do: "_#{test_name}", else: ""
    dir = "test/sipp/logs/#{timestamp}#{suffix}"

    File.mkdir_p!(dir)
    dir
  end

  @doc """
  Formats an IP address tuple as a string.

  ## Examples

      iex> format_ip({127, 0, 0, 1})
      "127.0.0.1"

      iex> format_ip({0, 0, 0, 0, 0, 0, 0, 1})
      "::1"
  """
  @spec format_ip(:inet.ip_address()) :: String.t()
  def format_ip(ip) do
    :inet.ntoa(ip) |> to_string()
  end

  @doc """
  Gets TLS certificate paths for testing.

  Returns the default test certificate paths used by TLS listeners.

  ## Returns

    * Map with `:certfile`, `:keyfile`, and `:cacertfile` keys
  """
  @spec get_tls_cert_paths() :: %{
          certfile: String.t(),
          keyfile: String.t(),
          cacertfile: String.t()
        }
  def get_tls_cert_paths do
    %{
      certfile: @default_tls_cert,
      keyfile: @default_tls_key,
      cacertfile: @default_tls_ca
    }
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp wait_loop(listener_pid, end_time) do
    if System.monotonic_time(:millisecond) > end_time do
      {:error, :timeout}
    else
      if Process.alive?(listener_pid) do
        # Give it a bit more time to fully initialize
        Process.sleep(10)
        :ok
      else
        Process.sleep(10)
        wait_loop(listener_pid, end_time)
      end
    end
  end
end
