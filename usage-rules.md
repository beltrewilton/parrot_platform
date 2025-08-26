# Parrot Platform Usage Rules

Parrot Platform provides Elixir libraries and OTP behaviours for building telecom applications with SIP protocol and media handling.

## Core Concepts

### Always use OTP behaviours
- Implement `Parrot.SipHandler` for SIP protocol events
- Implement `Parrot.MediaHandler` for media session events
- Both behaviours can be implemented in the same module

### Pattern matching is critical
Always use pattern matching on SIP messages and data structures instead of conditionals. This applies to ALL code in the Parrot platform:

```elixir
# GOOD - Multiple function clauses with pattern matching
def handle_invite(%{headers: %{"from" => %From{uri: %{user: "alice"}}}} = msg, state)
def handle_invite(%{method: "INVITE"} = msg, state)

def handle_info({:play_files, files, opts}, state) when is_list(opts)
def handle_info({:play_files, files, []}, state)

# BAD - Conditionals inside functions
def handle_invite(msg, state) do
  if msg.headers["from"].uri.user == "alice" do

def handle_info({:play_files, files, opts}, state) do
  if Keyword.get(opts, :loop) do  # NEVER DO THIS - use pattern matching!
```

**IMPORTANT FOR AI AGENTS**: When writing code for Parrot, ALWAYS prefer multiple function clauses with pattern matching over if/else/cond statements. Break complex conditionals into separate functions with descriptive names.

## Quick Start Pattern

```elixir
defmodule MyApp do
  use Parrot.SipHandler
  @behaviour Parrot.MediaHandler
  
  # SIP handler - handles protocol events
  def handle_invite(request, state) do
    {:ok, _pid} = Parrot.Media.MediaSession.start_link(
      id: generate_call_id(),
      role: :uas,
      media_handler: __MODULE__,
      handler_args: %{}
    )
    
    case Parrot.Media.MediaSession.process_offer(call_id, request.body) do
      {:ok, sdp_answer} -> {:respond, 200, "OK", %{}, sdp_answer}
      {:error, _} -> {:respond, 488, "Not Acceptable Here", %{}, ""}
    end
  end
  
  # MediaHandler - handles media events
  def handle_stream_start(_id, :outbound, state) do
    {{:play, "welcome.wav"}, state}
  end
end
```

## Key Modules

- `Parrot.Sip.Transport.StateMachine` - Start UDP/TCP transports
- `Parrot.Media.MediaSession` - Manage media sessions
- `Parrot.Sip.Message` - SIP message structure
- `Parrot.Sip.Dialog` - Dialog management

## Common Patterns

### Starting a UAS (server)
```elixir
handler = Parrot.Sip.Handler.new(MyApp.SipHandler, %{}, log_level: :info)
Parrot.Sip.Transport.StateMachine.start_udp(%{
  listen_port: 5060,
  handler: handler
})
```

### SipHandler callbacks
- `handle_invite/2` - Incoming calls
- `handle_ack/2` - Call confirmation  
- `handle_bye/2` - Call termination
- `handle_cancel/2` - Call cancellation
- `handle_response/2` - SIP responses
- `handle_request/2` - Other SIP methods

### MediaHandler callbacks
- `handle_info/2` - **PRIMARY CALLBACK** for message-based media control
  - `{:play_files, files, opts}` - Play audio files with options
  - `{:fork_audio, url, opts}` - Fork audio to WebSocket
  - `{:received_audio, data, metadata}` - Handle audio from external service
- `handle_stream_start/3` - Media stream begins
- `handle_play_complete/2` - Audio finished playing
- `handle_codec_negotiation/3` - Select codec preference

## Important Notes

- Uses gen_statem extensively (NOT just GenServer)
- SIP transactions and dialogs are state machines
- Media sessions integrate with Membrane multimedia libraries
- Pattern match on message structs for clean code
- Let it crash - supervisors handle failures

## Testing

```bash
# Run all tests
mix test

# Run SIPp integration tests
mix test test/sipp/test_scenarios.exs

# Enable SIP tracing
SIP_TRACE=true mix test
```

## Common Mistakes

1. **Not pattern matching** - Always pattern match SIP messages
2. **Fighting gen_statem** - Embrace state machines for transactions/dialogs
3. **Ignoring media callbacks** - Implement MediaHandler for audio
4. **Not handling all SIP methods** - Implement handle_request/2 fallback

## Example: Modern IVR with Message-Based Control

```elixir
defmodule MyIVR do
  use Parrot.UasHandler
  @behaviour Parrot.MediaHandler
  
  # UAS Handler - Accept call and trigger media
  def handle_invite(request, state) do
    {:ok, media_pid} = Parrot.Media.MediaSession.start_link(
      id: "call_123",
      role: :uas,
      media_handler: __MODULE__
    )
    
    case Parrot.Media.MediaSession.process_offer("call_123", request.body) do
      {:ok, sdp_answer} ->
        # Trigger IVR menu playback
        send(media_pid, {:play_files, ["welcome.wav", "menu.wav"], []})
        # Fork audio for transcription
        send(media_pid, {:fork_audio, "ws://transcribe.local/", bidirectional: true})
        
        {:respond, 200, "OK", %{}, sdp_answer, Map.put(state, :media_pid, media_pid)}
      {:error, _} ->
        {:respond, 488, "Not Acceptable Here", %{}, "", state}
    end
  end
  
  # MediaHandler - Pattern matching for different message types
  @impl Parrot.MediaHandler
  def handle_info({:play_files, files, opts}, state) when opts == [] do
    {[{:play_sequence, files}], Map.put(state, :playing, files)}
  end
  
  def handle_info({:play_files, files, [loop: true]}, state) do
    {[{:play_loop, files}], Map.put(state, :playing, files)}
  end
  
  def handle_info({:received_audio, data, %{source: "transcribe.local"}}, state) do
    # React to transcription results
    handle_transcription(data, state)
  end
  
  # Pattern match on transcription results
  defp handle_transcription(%{text: "main menu"}, state) do
    {[{:play_sequence, ["menu.wav"]}], state}
  end
  
  defp handle_transcription(%{text: "operator"}, state) do
    {[{:play_sequence, ["transferring.wav"]}], Map.put(state, :transfer, true)}
  end
  
  defp handle_transcription(_, state), do: {:noreply, state}
end
```