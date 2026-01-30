defmodule ParrotMedia.Fork.Types do
  @moduledoc """
  Type definitions for media forking functionality.

  Media forking allows real-time audio to be copied and sent to external
  destinations (WebSocket servers, RTP endpoints) for recording, transcription,
  or analysis while the main call continues.

  ## Direction Types

  - `:rx` - Fork incoming audio (what the remote party sends)
  - `:tx` - Fork outgoing audio (what the local party sends)
  - `:both` - Fork audio in both directions

  ## Format Types

  - `:pcmu` - G.711 mu-law (8kHz)
  - `:pcma` - G.711 A-law (8kHz)
  - `:opus` - Opus codec
  - `:raw` - Raw PCM audio

  ## Destination Types

  - `{:websocket, url}` - WebSocket connection for streaming
  - `{:rtp, {ip_tuple, port}}` - RTP stream to IP:port
  """

  @typedoc """
  Direction of media to fork.

  - `:rx` - Receive direction (incoming from remote)
  - `:tx` - Transmit direction (outgoing to remote)
  - `:both` - Both directions
  """
  @type direction :: :rx | :tx | :both

  @typedoc """
  Audio format for forked media.
  """
  @type format :: :pcmu | :pcma | :opus | :raw

  @typedoc """
  Destination for forked media.
  """
  @type destination ::
          {:websocket, String.t()}
          | {:rtp, {:inet.ip_address(), :inet.port_number()}}

  @typedoc """
  Status of a media fork.
  """
  @type fork_status :: :pending | :connecting | :active | :paused | :stopped | :error

  defmodule ForkConfig do
    @moduledoc """
    Configuration for a media fork.

    ## Required Fields

    - `:id` - Unique identifier for this fork
    - `:destination` - Where to send the forked media
    - `:direction` - Which direction(s) to fork (:rx, :tx, or :both)

    ## Optional Fields

    - `:format` - Audio format (defaults to source format)
    - `:sample_rate` - Sample rate in Hz
    - `:label` - Human-readable label for this fork
    - `:started_at` - When the fork was started (set automatically)
    """

    @enforce_keys [:id, :destination, :direction]
    defstruct [
      :id,
      :destination,
      :direction,
      :format,
      :sample_rate,
      :label,
      :started_at
    ]

    @type t :: %__MODULE__{
            id: String.t(),
            destination: ParrotMedia.Fork.Types.destination(),
            direction: ParrotMedia.Fork.Types.direction(),
            format: ParrotMedia.Fork.Types.format() | nil,
            sample_rate: pos_integer() | nil,
            label: String.t() | nil,
            started_at: DateTime.t() | nil
          }
  end

  defmodule ForkState do
    @moduledoc """
    Runtime state for an active media fork.

    ## Required Fields

    - `:config` - The ForkConfig for this fork
    - `:status` - Current status of the fork

    ## Optional Fields

    - `:connection_pid` - PID of the connection process (WebSocket client, etc.)
    - `:bytes_sent` - Total bytes sent to destination
    - `:packets_sent` - Total packets sent to destination
    """

    @enforce_keys [:config, :status]
    defstruct [
      :config,
      :status,
      :connection_pid,
      bytes_sent: 0,
      packets_sent: 0
    ]

    @type t :: %__MODULE__{
            config: ForkConfig.t(),
            status: ParrotMedia.Fork.Types.fork_status(),
            connection_pid: pid() | nil,
            bytes_sent: non_neg_integer(),
            packets_sent: non_neg_integer()
          }
  end
end
