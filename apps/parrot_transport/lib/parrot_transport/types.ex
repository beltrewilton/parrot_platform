defmodule ParrotTransport.Types do
  @moduledoc """
  Type definitions and message contracts for ParrotTransport.

  This module defines the contract between transport and application layers.
  All types are protocol-agnostic - the transport layer has no knowledge of
  SIP, RTP, or any other application protocol.
  """

  defmodule Metadata do
    @moduledoc """
    Transport-level metadata for incoming packets.
    """
    defstruct [
      :timestamp,
      :connection_id,
      :tls_info,
      extra: %{}
    ]

    @type t :: %__MODULE__{
            timestamp: integer() | nil,
            connection_id: String.t() | nil,
            tls_info: map() | nil,
            extra: map()
          }
  end

  defmodule Source do
    @moduledoc """
    Source address information for a packet.

    Contains both local and remote addressing, plus optional connection
    reference for stream-based transports.
    """
    @enforce_keys [:transport, :remote_addr, :local_addr]
    defstruct [:transport, :remote_addr, :local_addr, :connection]

    @type t :: %__MODULE__{
            transport: :udp | :tcp | :tls,
            remote_addr: {:inet.ip_address(), :inet.port_number()},
            local_addr: {:inet.ip_address(), :inet.port_number()},
            connection: pid() | nil
          }
  end

  defmodule IncomingPacket do
    @moduledoc """
    Message sent from transport to registered handlers.

    Handlers receive messages in the format:
    `{:incoming_packet, IncomingPacket.t()}`
    """
    @enforce_keys [:data, :source, :metadata]
    defstruct [:data, :source, :metadata]

    @type t :: %__MODULE__{
            data: binary(),
            source: Source.t(),
            metadata: Metadata.t()
          }
  end

  defmodule ListenerConfig do
    @moduledoc """
    Configuration for transport listeners.

    All transport types use this unified configuration structure.
    Transport-specific fields (like certfile for TLS) can be included
    and will be ignored by transports that don't need them.
    """
    @enforce_keys [:transport, :port]
    defstruct [
      :transport,
      :port,
      ip: {0, 0, 0, 0},
      name: nil,
      # TLS specific
      certfile: nil,
      keyfile: nil,
      cacertfile: nil,
      # TCP/TLS specific
      max_connections: 10_000,
      accept_pool_size: 10,
      # Common options
      buffer_size: 65_536,
      trace: false
    ]

    @type t :: %__MODULE__{
            transport: :udp | :tcp | :tls,
            port: :inet.port_number(),
            ip: :inet.ip_address(),
            name: atom() | nil,
            certfile: Path.t() | nil,
            keyfile: Path.t() | nil,
            cacertfile: Path.t() | nil,
            max_connections: pos_integer(),
            accept_pool_size: pos_integer(),
            buffer_size: pos_integer(),
            trace: boolean()
          }
  end

  @typedoc """
  Destination for outgoing packets.

  Can be either an address tuple for connectionless/new connections,
  or a connection PID for established stream connections.
  """
  @type destination ::
          {:address, {:inet.ip_address(), :inet.port_number()}}
          | {:connection, pid()}

  @type source :: Source.t()
  @type metadata :: Metadata.t()
  @type incoming_packet :: IncomingPacket.t()
  @type listener_config :: ListenerConfig.t()
end
