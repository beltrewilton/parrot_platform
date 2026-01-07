defmodule Parrot.Call do
  @moduledoc """
  Represents a VoIP call and provides a pipeline-friendly API for call operations.

  The Call struct is the central data structure for building call handling logic
  in Parrot. It supports pipeline operations via the `|>` operator, allowing you
  to chain signaling, media, and bridging operations in a declarative style.

  ## Usage

  Build call handling pipelines:

      call
      |> answer()
      |> assign(:menu, :main)
      |> play("welcome.wav")
      |> prompt("enter-pin.wav", collect: [max: 4, timeout: 10_000])

  Each operation returns the updated call struct with the operation recorded
  in an internal list for later execution by the framework.

  ## Fields

  * `:id` - Unique identifier for this call session
  * `:handler` - The module implementing `Parrot.InviteHandler` for this call
  * `:from` - The SIP From URI (caller)
  * `:to` - The SIP To URI (callee)
  * `:call_id` - SIP Call-ID header value
  * `:state` - Current call state (`:incoming`, `:ringing`, `:answered`, `:terminated`)
  * `:method` - The SIP method (typically "INVITE")
  * `:assigns` - Per-call state storage (map)
  * `:__operations__` - Internal list of operations to execute (do not modify directly)

  ## Operations

  ### Signaling
  * `answer/1`, `answer/2` - Answer the call
  * `reject/2` - Reject the call with a status code
  * `hangup/1` - Hang up the call

  ### State
  * `assign/3` - Store per-call state

  ### Playback
  * `play/2`, `play/3` - Play audio file(s)

  ### Recording
  * `record/2`, `record/3` - Start recording
  * `stop_record/1` - Stop recording

  ### DTMF
  * `collect_dtmf/2` - Collect DTMF digits
  * `prompt/3` - Play audio and collect DTMF

  ### Bridging
  * `bridge/2`, `bridge/3` - Bridge to another endpoint
  * `fork/2`, `fork/3` - Fork call to multiple endpoints
  """

  @type call_state :: :incoming | :ringing | :answered | :terminated

  @type t :: %__MODULE__{
          id: String.t() | nil,
          handler: module() | nil,
          from: String.t() | nil,
          to: String.t() | nil,
          call_id: String.t() | nil,
          state: call_state(),
          method: String.t() | nil,
          assigns: map(),
          __operations__: list()
        }

  defstruct id: nil,
            handler: nil,
            from: nil,
            to: nil,
            call_id: nil,
            state: :incoming,
            method: nil,
            assigns: %{},
            __operations__: []

  @doc """
  Creates a new Call struct from keyword options.

  ## Options

  * `:id` - Unique call ID (auto-generated if not provided)
  * `:handler` - Handler module implementing `Parrot.InviteHandler`
  * `:from` - The SIP From URI
  * `:to` - The SIP To URI
  * `:call_id` - SIP Call-ID header
  * `:method` - The SIP method

  ## Examples

      Call.new(from: "sip:alice@example.com", to: "sip:bob@example.com", method: "INVITE")

  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      id: Keyword.get(opts, :id) || generate_id(),
      handler: Keyword.get(opts, :handler),
      from: Keyword.get(opts, :from),
      to: Keyword.get(opts, :to),
      call_id: Keyword.get(opts, :call_id),
      state: Keyword.get(opts, :state, :incoming),
      method: Keyword.get(opts, :method),
      assigns: Keyword.get(opts, :assigns, %{}),
      __operations__: []
    }
  end

  @doc """
  Generates a unique call ID.

  ## Examples

      iex> id = Parrot.Call.generate_id()
      iex> is_binary(id) and String.length(id) > 0
      true
  """
  @spec generate_id() :: String.t()
  def generate_id do
    Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end

  # ---------------------------------------------------------------------------
  # Signaling Operations
  # ---------------------------------------------------------------------------

  @doc """
  Answers the call with default options.

  ## Examples

      call |> answer()

  """
  @spec answer(t()) :: t()
  def answer(%__MODULE__{} = call) do
    add_operation(call, {:answer, []})
  end

  @doc """
  Answers the call with SDP options.

  ## Options

  * `:codecs` - List of codecs to offer

  ## Examples

      call |> answer(codecs: [:pcmu, :pcma])

  """
  @spec answer(t(), keyword()) :: t()
  def answer(%__MODULE__{} = call, opts) when is_list(opts) do
    add_operation(call, {:answer, opts})
  end

  @doc """
  Rejects the call with the given SIP status code.

  ## Examples

      call |> reject(486)  # Busy Here
      call |> reject(403)  # Forbidden

  """
  @spec reject(t(), integer()) :: t()
  def reject(%__MODULE__{} = call, status_code) when is_integer(status_code) do
    add_operation(call, {:reject, status_code})
  end

  @doc """
  Hangs up the call.

  ## Examples

      call |> hangup()

  """
  @spec hangup(t()) :: t()
  def hangup(%__MODULE__{} = call) do
    add_operation(call, {:hangup, []})
  end

  # ---------------------------------------------------------------------------
  # State Operations
  # ---------------------------------------------------------------------------

  @doc """
  Assigns a key-value pair to the call's assigns map.

  Assigns are per-call state that persists for the duration of the call.
  Use this to store menu state, retry counters, or any call-specific data.

  ## Examples

      call
      |> assign(:menu, :main)
      |> assign(:retries, 0)

  """
  @spec assign(t(), atom(), term()) :: t()
  def assign(%__MODULE__{assigns: assigns} = call, key, value) when is_atom(key) do
    %{call | assigns: Map.put(assigns, key, value)}
  end

  # ---------------------------------------------------------------------------
  # Playback Operations
  # ---------------------------------------------------------------------------

  @doc """
  Plays an audio file or list of files.

  ## Examples

      call |> play("welcome.wav")
      call |> play(["intro.wav", "menu.wav"])

  """
  @spec play(t(), String.t() | list(String.t())) :: t()
  def play(%__MODULE__{} = call, file_or_files) do
    add_operation(call, {:play, file_or_files, []})
  end

  @doc """
  Plays an audio file with options.

  ## Options

  * `:loop` - Whether to loop the audio (default: false)
  * `:volume` - Volume level (0.0 to 1.0)

  ## Examples

      call |> play("music.wav", loop: true)
      call |> play("audio.wav", loop: true, volume: 0.8)

  """
  @spec play(t(), String.t() | list(String.t()), keyword()) :: t()
  def play(%__MODULE__{} = call, file_or_files, opts) when is_list(opts) do
    add_operation(call, {:play, file_or_files, opts})
  end

  # ---------------------------------------------------------------------------
  # Recording Operations
  # ---------------------------------------------------------------------------

  @doc """
  Starts recording to the specified file.

  ## Examples

      call |> record("recording.wav")

  """
  @spec record(t(), String.t()) :: t()
  def record(%__MODULE__{} = call, filename) when is_binary(filename) do
    add_operation(call, {:record, filename, []})
  end

  @doc """
  Starts recording with options.

  ## Options

  * `:max_duration` - Maximum recording duration in milliseconds
  * `:beep` - Whether to play a beep before recording (default: false)

  ## Examples

      call |> record("recording.wav", max_duration: 60_000)
      call |> record("recording.wav", max_duration: 60_000, beep: true)

  """
  @spec record(t(), String.t(), keyword()) :: t()
  def record(%__MODULE__{} = call, filename, opts)
      when is_binary(filename) and is_list(opts) do
    add_operation(call, {:record, filename, opts})
  end

  @doc """
  Stops the current recording.

  ## Examples

      call |> stop_record()

  """
  @spec stop_record(t()) :: t()
  def stop_record(%__MODULE__{} = call) do
    add_operation(call, {:stop_record, []})
  end

  # ---------------------------------------------------------------------------
  # DTMF Operations
  # ---------------------------------------------------------------------------

  @doc """
  Collects DTMF digits from the caller.

  ## Options

  * `:max` - Maximum number of digits to collect
  * `:timeout` - Timeout in milliseconds
  * `:terminators` - List of terminating digits (e.g., ["#", "*"])

  ## Examples

      call |> collect_dtmf(max: 4, timeout: 5_000)
      call |> collect_dtmf(max: 16, terminators: ["#"])

  """
  @spec collect_dtmf(t(), keyword()) :: t()
  def collect_dtmf(%__MODULE__{} = call, opts) when is_list(opts) do
    add_operation(call, {:collect_dtmf, opts})
  end

  @doc """
  Plays an audio file and collects DTMF digits.

  This is a convenience function that combines `play/2` and `collect_dtmf/2`.

  ## Options

  * `:collect` - Keyword list of collect_dtmf options (max, timeout, terminators)

  ## Examples

      call |> prompt("enter-pin.wav", collect: [max: 4, timeout: 10_000])

  """
  @spec prompt(t(), String.t(), keyword()) :: t()
  def prompt(%__MODULE__{} = call, file, opts) when is_binary(file) and is_list(opts) do
    add_operation(call, {:prompt, file, opts})
  end

  # ---------------------------------------------------------------------------
  # Bridging Operations
  # ---------------------------------------------------------------------------

  @doc """
  Bridges the call to another endpoint.

  ## Examples

      call |> bridge("sip:dest@somewhere")

  """
  @spec bridge(t(), String.t()) :: t()
  def bridge(%__MODULE__{} = call, destination) when is_binary(destination) do
    add_operation(call, {:bridge, destination, []})
  end

  @doc """
  Bridges the call to another endpoint with options.

  ## Options

  * `:timeout` - Timeout in milliseconds
  * `:headers` - Map of headers to add to the outgoing INVITE
  * `:handler` - B-leg handler module

  ## Examples

      call |> bridge("sip:dest@somewhere", timeout: 30_000)
      call |> bridge("sip:dest@somewhere", handler: MyBLegHandler)

  """
  @spec bridge(t(), String.t(), keyword()) :: t()
  def bridge(%__MODULE__{} = call, destination, opts)
      when is_binary(destination) and is_list(opts) do
    add_operation(call, {:bridge, destination, opts})
  end

  @doc """
  Forks the call to multiple endpoints.

  ## Examples

      destinations = [
        {"sip:alice@device1", handler: Handler1},
        {"sip:alice@device2", handler: Handler2}
      ]
      call |> fork(destinations)

  """
  @spec fork(t(), list()) :: t()
  def fork(%__MODULE__{} = call, destinations) when is_list(destinations) do
    add_operation(call, {:fork, destinations, []})
  end

  @doc """
  Forks the call to multiple endpoints with options.

  ## Options

  * `:strategy` - Fork strategy (`:first_answer`, `:ring_all`)
  * `:timeout` - Timeout in milliseconds

  ## Examples

      call |> fork(destinations, strategy: :first_answer, timeout: 30_000)

  """
  @spec fork(t(), list(), keyword()) :: t()
  def fork(%__MODULE__{} = call, destinations, opts)
      when is_list(destinations) and is_list(opts) do
    add_operation(call, {:fork, destinations, opts})
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  @doc """
  Returns the list of operations in execution order.

  ## Examples

      call
      |> answer()
      |> play("welcome.wav")
      |> Call.get_operations()
      #=> [{:answer, []}, {:play, "welcome.wav", []}]

  """
  @spec get_operations(t()) :: list()
  def get_operations(%__MODULE__{__operations__: operations}) do
    Enum.reverse(operations)
  end

  # Private helper to add an operation to the list
  # Operations are stored in reverse order for O(1) prepend, reversed on read
  defp add_operation(%__MODULE__{__operations__: operations} = call, operation) do
    %{call | __operations__: [operation | operations]}
  end
end
