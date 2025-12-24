defmodule ParrotMedia.SwitchableFileSource do
  @moduledoc """
  A Membrane source element that reads WAV files and supports dynamic file switching.

  This element combines WAV file reading and parsing into a single component that can:
  - Switch between files seamlessly without ending the stream
  - Play sequences of files in order
  - Loop files continuously
  - Notify a media handler when files complete

  ## Features

  - **File Switching**: Switch to a new file mid-stream via `:switch_file` notification
  - **Playlist Support**: Play sequences or loops via `:play_sequence` and `:play_loop`
  - **WAV Parsing**: Automatically parses WAV headers and outputs raw audio data
  - **Handler Callbacks**: Notifies media handler when files complete for dynamic playlists

  ## Output

  Outputs raw audio data in the format specified by the WAV file header.

  ## Notifications

  Accepts the following parent notifications:

  - `{:switch_file, path}` - Switch to a new file immediately
  - `{:play_sequence, paths}` - Play a list of files in order
  - `{:play_loop, paths}` - Play a list of files in a continuous loop

  ## Example

      options = [
        initial_file: "/path/to/audio.wav",
        media_handler: MyHandler,
        handler_state: %{},
        session_id: "session-123"
      ]

      child(:source, %SwitchableFileSource{options})
      |> child(:encoder, SomeEncoder)
  """

  use Membrane.Source

  require Logger

  alias Membrane.{Buffer, RawAudio}

  def_output_pad(:output,
    accepted_format: RawAudio,
    flow_control: :manual
  )

  def_options(
    initial_file: [
      spec: String.t(),
      description: "Path to the initial WAV file to play"
    ],
    media_handler: [
      spec: module(),
      description: "Media handler module for callbacks"
    ],
    handler_state: [
      spec: term(),
      description: "Initial state for the media handler"
    ],
    session_id: [
      spec: String.t(),
      description: "Session ID for logging"
    ],
    chunk_size: [
      spec: pos_integer(),
      default: 4096,
      description: "Number of bytes to read per chunk"
    ]
  )

  @impl true
  def handle_init(_ctx, options) do
    state = %{
      current_file: options.initial_file,
      fd: nil,
      remaining_bytes: nil,
      chunk_size: options.chunk_size,
      header_parsed?: false,
      audio_format: nil,
      playlist: [],
      playlist_mode: :none,
      loop_files: [],
      media_handler: options.media_handler,
      handler_state: options.handler_state,
      session_id: options.session_id
    }

    Logger.debug(
      "[SwitchableFileSource:#{state.session_id}] Initialized with file: #{options.initial_file}"
    )

    {[], state}
  end

  @impl true
  def handle_setup(_ctx, state) do
    Logger.debug("[SwitchableFileSource:#{state.session_id}] Opening initial file")

    case open_file(state.current_file, state) do
      {:ok, new_state} ->
        {[], new_state}

      {:error, reason} ->
        Logger.error(
          "[SwitchableFileSource:#{state.session_id}] Failed to open initial file: #{inspect(reason)}"
        )

        raise "Failed to open initial file #{state.current_file}: #{inspect(reason)}"
    end
  end

  @impl true
  def handle_playing(_ctx, state) do
    # Send stream format based on parsed WAV header
    if state.audio_format do
      Logger.debug(
        "[SwitchableFileSource:#{state.session_id}] Sending stream format: #{inspect(state.audio_format)}"
      )

      {[stream_format: {:output, state.audio_format}], state}
    else
      Logger.error("[SwitchableFileSource:#{state.session_id}] No audio format available")
      {[], state}
    end
  end

  @impl true
  def handle_demand(:output, size, :buffers, _ctx, state) do
    # Calculate bytes to read based on demand
    bytes_to_read = min(size * state.chunk_size, state.remaining_bytes || state.chunk_size)

    case IO.binread(state.fd, bytes_to_read) do
      :eof ->
        handle_file_complete(state)

      {:error, reason} ->
        Logger.error("[SwitchableFileSource:#{state.session_id}] Read error: #{inspect(reason)}")

        {[end_of_stream: :output], state}

      data when is_binary(data) and byte_size(data) > 0 ->
        buffer = %Buffer{payload: data}

        new_remaining =
          if state.remaining_bytes, do: state.remaining_bytes - byte_size(data), else: nil

        new_state = %{state | remaining_bytes: new_remaining}

        Logger.debug(
          "[SwitchableFileSource:#{state.session_id}] Read #{byte_size(data)} bytes, #{new_remaining || "unknown"} remaining"
        )

        # Check if we've exhausted the file
        if new_remaining != nil and new_remaining <= 0 do
          # File complete, handle next action
          handle_file_complete(%{new_state | remaining_bytes: 0})
        else
          # Continue reading - send buffer and redemand for more
          {[buffer: {:output, buffer}, redemand: :output], new_state}
        end

      data when is_binary(data) and byte_size(data) == 0 ->
        # Empty read means EOF
        handle_file_complete(state)
    end
  end

  @impl true
  def handle_parent_notification({:switch_file, new_file}, _ctx, state) do
    Logger.info("[SwitchableFileSource:#{state.session_id}] Switching to file: #{new_file}")

    # Close current file
    if state.fd, do: File.close(state.fd)

    # Open new file
    new_state = %{state | current_file: new_file, playlist: [], playlist_mode: :none}

    case open_file(new_file, new_state) do
      {:ok, updated_state} ->
        # Send new stream format if it changed
        if updated_state.audio_format != state.audio_format do
          {[stream_format: {:output, updated_state.audio_format}], updated_state}
        else
          {[], updated_state}
        end

      {:error, reason} ->
        Logger.error(
          "[SwitchableFileSource:#{state.session_id}] Failed to switch file: #{inspect(reason)}"
        )

        {[end_of_stream: :output], state}
    end
  end

  @impl true
  def handle_parent_notification({:play_sequence, files}, _ctx, state) do
    Logger.info("[SwitchableFileSource:#{state.session_id}] Playing sequence: #{inspect(files)}")

    new_state = %{state | playlist: files, playlist_mode: :sequence, loop_files: []}
    {[], new_state}
  end

  @impl true
  def handle_parent_notification({:play_loop, files}, _ctx, state) do
    Logger.info("[SwitchableFileSource:#{state.session_id}] Playing loop: #{inspect(files)}")

    new_state = %{state | playlist: files, playlist_mode: :loop, loop_files: files}
    {[], new_state}
  end

  # Private Functions

  defp open_file(file_path, state) do
    Logger.debug("[SwitchableFileSource:#{state.session_id}] Opening file: #{file_path}")

    case File.open(file_path, [:read, :binary]) do
      {:ok, fd} ->
        case IO.binread(fd, 44) do
          header when is_binary(header) ->
            case parse_wav_header(header) do
              {:ok, audio_format, data_size} ->
                Logger.debug(
                  "[SwitchableFileSource:#{state.session_id}] Parsed WAV: format=#{inspect(audio_format)}, data_size=#{data_size}"
                )

                new_state = %{
                  state
                  | fd: fd,
                    header_parsed?: true,
                    audio_format: audio_format,
                    remaining_bytes: data_size
                }

                {:ok, new_state}

              {:error, reason} ->
                File.close(fd)

                Logger.error(
                  "[SwitchableFileSource:#{state.session_id}] Failed to parse WAV header: #{inspect(reason)}"
                )

                {:error, reason}
            end

          :eof ->
            File.close(fd)

            Logger.error(
              "[SwitchableFileSource:#{state.session_id}] File too small to contain WAV header"
            )

            {:error, :file_too_small}

          {:error, reason} ->
            File.close(fd)

            Logger.error(
              "[SwitchableFileSource:#{state.session_id}] Failed to read WAV header: #{inspect(reason)}"
            )

            {:error, reason}
        end

      {:error, reason} ->
        Logger.error(
          "[SwitchableFileSource:#{state.session_id}] Failed to open file #{file_path}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp parse_wav_header(<<
         # RIFF header
         "RIFF",
         _file_size::little-32,
         "WAVE",
         # fmt chunk
         "fmt ",
         fmt_size::little-32,
         audio_format::little-16,
         num_channels::little-16,
         sample_rate::little-32,
         _byte_rate::little-32,
         _block_align::little-16,
         bits_per_sample::little-16,
         # Skip any extra fmt data
         _extra_fmt::binary-size(fmt_size - 16),
         # data chunk
         "data",
         data_size::little-32
       >>) do
    # Validate PCM format
    if audio_format != 1 do
      {:error, {:unsupported_format, audio_format}}
    else
      format = %RawAudio{
        channels: num_channels,
        sample_rate: sample_rate,
        sample_format: sample_format_from_bits(bits_per_sample)
      }

      {:ok, format, data_size}
    end
  end

  defp parse_wav_header(_invalid) do
    {:error, :invalid_wav_header}
  end

  defp sample_format_from_bits(8), do: :u8
  defp sample_format_from_bits(16), do: :s16le
  defp sample_format_from_bits(24), do: :s24le
  defp sample_format_from_bits(32), do: :s32le
  defp sample_format_from_bits(bits), do: {:error, {:unsupported_bit_depth, bits}}

  defp handle_file_complete(state) do
    Logger.debug(
      "[SwitchableFileSource:#{state.session_id}] File complete: #{state.current_file}"
    )

    # Check playlist first
    case {state.playlist_mode, state.playlist} do
      # Sequence mode with more files
      {:sequence, [next_file | remaining]} ->
        Logger.debug(
          "[SwitchableFileSource:#{state.session_id}] Playing next file in sequence: #{next_file}"
        )

        switch_to_next_file(next_file, %{state | playlist: remaining})

      # Loop mode - restart from beginning
      {:loop, []} when state.loop_files != [] ->
        [next_file | remaining] = state.loop_files

        Logger.debug("[SwitchableFileSource:#{state.session_id}] Looping back to: #{next_file}")

        switch_to_next_file(next_file, %{state | playlist: remaining})

      # Loop mode with more files in current loop
      {:loop, [next_file | remaining]} ->
        Logger.debug(
          "[SwitchableFileSource:#{state.session_id}] Playing next file in loop: #{next_file}"
        )

        switch_to_next_file(next_file, %{state | playlist: remaining})

      # No playlist - ask handler what to do
      _ ->
        Logger.debug(
          "[SwitchableFileSource:#{state.session_id}] Calling handler.handle_play_complete"
        )

        case state.media_handler.handle_play_complete(state.current_file, state.handler_state) do
          # Wrapped responses with new handler state
          {{:play, new_file}, new_handler_state} ->
            Logger.debug(
              "[SwitchableFileSource:#{state.session_id}] Handler requested play: #{new_file}"
            )

            switch_to_next_file(new_file, %{state | handler_state: new_handler_state})

          {{:play_sequence, files}, new_handler_state} when is_list(files) and length(files) > 0 ->
            Logger.debug(
              "[SwitchableFileSource:#{state.session_id}] Handler requested sequence: #{inspect(files)}"
            )

            [first_file | remaining] = files

            new_state = %{
              state
              | playlist: remaining,
                playlist_mode: :sequence,
                loop_files: [],
                handler_state: new_handler_state
            }

            switch_to_next_file(first_file, new_state)

          {{:play_loop, files}, new_handler_state} when is_list(files) and length(files) > 0 ->
            Logger.debug(
              "[SwitchableFileSource:#{state.session_id}] Handler requested loop: #{inspect(files)}"
            )

            [first_file | remaining] = files

            new_state = %{
              state
              | playlist: remaining,
                playlist_mode: :loop,
                loop_files: files,
                handler_state: new_handler_state
            }

            switch_to_next_file(first_file, new_state)

          {:stop, new_handler_state} ->
            Logger.debug("[SwitchableFileSource:#{state.session_id}] Handler requested stop")
            {[end_of_stream: :output], %{state | handler_state: new_handler_state}}

          # Unwrapped responses (no handler state update)
          {:play, new_file} ->
            Logger.debug(
              "[SwitchableFileSource:#{state.session_id}] Handler requested play (unwrapped): #{new_file}"
            )

            switch_to_next_file(new_file, state)

          {:play_sequence, files} when is_list(files) and length(files) > 0 ->
            Logger.debug(
              "[SwitchableFileSource:#{state.session_id}] Handler requested sequence (unwrapped): #{inspect(files)}"
            )

            [first_file | remaining] = files
            new_state = %{state | playlist: remaining, playlist_mode: :sequence, loop_files: []}
            switch_to_next_file(first_file, new_state)

          {:play_loop, files} when is_list(files) and length(files) > 0 ->
            Logger.debug(
              "[SwitchableFileSource:#{state.session_id}] Handler requested loop (unwrapped): #{inspect(files)}"
            )

            [first_file | remaining] = files
            new_state = %{state | playlist: remaining, playlist_mode: :loop, loop_files: files}
            switch_to_next_file(first_file, new_state)

          {:noreply, new_handler_state} ->
            Logger.debug("[SwitchableFileSource:#{state.session_id}] Handler returned noreply")
            {[end_of_stream: :output], %{state | handler_state: new_handler_state}}

          other ->
            Logger.warning(
              "[SwitchableFileSource:#{state.session_id}] Unexpected handler response: #{inspect(other)}, stopping"
            )

            {[end_of_stream: :output], state}
        end
    end
  end

  defp switch_to_next_file(new_file, state) do
    # Close current file
    if state.fd, do: File.close(state.fd)

    # Open new file
    case open_file(new_file, %{state | current_file: new_file}) do
      {:ok, new_state} ->
        # Send new stream format if it changed, then redemand to start reading
        actions =
          if new_state.audio_format != state.audio_format do
            [stream_format: {:output, new_state.audio_format}, redemand: :output]
          else
            [redemand: :output]
          end

        {actions, new_state}

      {:error, reason} ->
        Logger.error(
          "[SwitchableFileSource:#{state.session_id}] Failed to open next file: #{inspect(reason)}"
        )

        {[end_of_stream: :output], state}
    end
  end
end
