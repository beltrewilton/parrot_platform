# Complete Dialog Statem Refactoring Report

## Executive Summary
This refactoring replaces **Dialog helper functions** and **Message.get_header calls** with direct pattern matching on the Message struct. This will eliminate 10 helper functions and make the code more performant and idiomatic.

---

## Part 1: Replace Dialog.is_early?/1 (3 locations)

### **Location 1: Line 195**
```elixir
# CURRENT:
initial_state = if Dialog.is_early?(dialog), do: :early, else: :confirmed
Logger.info("dialog #{inspect(data.id)}: starting in #{inspect(initial_state)} state")

# REFACTORED:
initial_state = dialog.state
Logger.info("dialog #{inspect(data.id)}: starting in #{inspect(initial_state)} state")
```
**Rationale:** Dialog.uas_create already sets the correct state. No conditional needed.

---

### **Location 2: Line 239**
```elixir
# CURRENT:
initial_state = if Dialog.is_early?(dialog), do: :early, else: :confirmed
Logger.info("dialog #{inspect(dialog.id)}: starting in #{inspect(initial_state)} state")

# REFACTORED:
initial_state = dialog.state
Logger.info("dialog #{inspect(dialog.id)}: starting in #{inspect(initial_state)} state")
```

---

### **Location 3: Line 264**
```elixir
# CURRENT:
initial_state = if Dialog.is_early?(dialog), do: :early, else: :confirmed
Logger.info("dialog #{inspect(dialog.id)}: starting in #{inspect(initial_state)} state")

# REFACTORED:
initial_state = dialog.state
Logger.info("dialog #{inspect(dialog.id)}: starting in #{inspect(initial_state)} state")
```

---

## Part 2: Replace Dialog.from_message/1 + Dialog.is_complete?/1 + Dialog.to_string/1

### **Location 4: Lines 278-301 (uas_find/1)**

```elixir
# CURRENT:
@spec uas_find(Message.t()) :: {:ok, dialog_handle()} | :not_found
def uas_find(%Message{} = req_sip_msg) do
  # Try to extract dialog ID from the message
  dialog_id = Dialog.from_message(req_sip_msg)

  if Dialog.is_complete?(dialog_id) do
    dialog_id_str = Dialog.to_string(dialog_id)
    Logger.info("uas_find: looking for dialog with ID #{inspect(dialog_id_str)}")
    result = find_dialog(dialog_id_str)

    case result do
      {:ok, pid} ->
        Logger.info("uas_find: found dialog #{inspect(dialog_id_str)} at PID #{inspect(pid)}")
        {:ok, pid}

      {:error, :no_dialog} ->
        Logger.warning("uas_find: dialog #{inspect(dialog_id_str)} not found in registry")
        :not_found
    end
  else
    Logger.debug("uas_find: incomplete dialog ID, not searching")
    :not_found
  end
end

# REFACTORED:
@spec uas_find(Message.t()) :: {:ok, dialog_handle()} | :not_found
def uas_find(%Message{
      from: %{parameters: %{"tag" => from_tag}},
      to: %{parameters: %{"tag" => to_tag}},
      call_id: call_id
    }) do
  # For UAS (incoming request): local=to_tag (us), remote=from_tag (them)
  dialog_id_str = "#{call_id};local=#{to_tag};remote=#{from_tag};uas"
  Logger.info("uas_find: looking for dialog with ID #{inspect(dialog_id_str)}")

  case find_dialog(dialog_id_str) do
    {:ok, pid} ->
      Logger.info("uas_find: found dialog #{inspect(dialog_id_str)} at PID #{inspect(pid)}")
      {:ok, pid}

    {:error, :no_dialog} ->
      Logger.warning("uas_find: dialog #{inspect(dialog_id_str)} not found in registry")
      :not_found
  end
end

def uas_find(%Message{}) do
  Logger.debug("uas_find: incomplete dialog ID, not searching")
  :not_found
end
```

---

### **Location 5: Lines 303-338 (uas_request/1)**

```elixir
# CURRENT:
@spec uas_request(Message.t()) :: :process | {:reply, Message.t()}
def uas_request(%Message{} = sip_msg) do
  Logger.debug("dialog: uas_request #{inspect(sip_msg)}")

  # Check if this message has a complete dialog ID
  dialog_id = Dialog.from_message(sip_msg)

  if Dialog.is_complete?(dialog_id) do
    dialog_id_str = Dialog.to_string(dialog_id)
    Logger.debug("dialog: found dialog id #{inspect(dialog_id_str)} in request")

    case find_dialog(dialog_id_str) do
      {:error, :no_dialog} ->
        Logger.debug(
          "dialog #{uas_log_id(sip_msg)}: dialog not found (dialog tracking not yet implemented)"
        )

        resp = Message.reply(sip_msg, 481, "Call/Transaction Does Not Exist")
        {:reply, resp}

      {:ok, dialog_pid} ->
        Logger.debug("dialog #{inspect(dialog_pid)}: found dialog")

        try do
          :gen_statem.call(dialog_pid, {:uas_request, sip_msg}, 5000)
        catch
          :exit, {reason, _} when reason in [:normal, :noproc, :timeout] ->
            resp = Message.reply(sip_msg, 481, "Call/Transaction Does Not Exist")
            {:reply, resp}
        end
    end
  else
    Logger.debug("dialog: no complete dialog id in request")
    uas_validate_request(sip_msg)
  end
end

# REFACTORED:
@spec uas_request(Message.t()) :: :process | {:reply, Message.t()}
def uas_request(%Message{
      from: %{parameters: %{"tag" => from_tag}},
      to: %{parameters: %{"tag" => to_tag}},
      call_id: call_id
    } = sip_msg) do
  Logger.debug("dialog: uas_request #{inspect(sip_msg)}")

  # For UAS: local=to_tag, remote=from_tag
  dialog_id_str = "#{call_id};local=#{to_tag};remote=#{from_tag};uas"
  Logger.debug("dialog: found dialog id #{inspect(dialog_id_str)} in request")

  case find_dialog(dialog_id_str) do
    {:error, :no_dialog} ->
      Logger.debug(
        "dialog #{uas_log_id(sip_msg)}: dialog not found (dialog tracking not yet implemented)"
      )
      resp = Message.reply(sip_msg, 481, "Call/Transaction Does Not Exist")
      {:reply, resp}

    {:ok, dialog_pid} ->
      Logger.debug("dialog #{inspect(dialog_pid)}: found dialog")

      try do
        :gen_statem.call(dialog_pid, {:uas_request, sip_msg}, 5000)
      catch
        :exit, {reason, _} when reason in [:normal, :noproc, :timeout] ->
          resp = Message.reply(sip_msg, 481, "Call/Transaction Does Not Exist")
          {:reply, resp}
      end
  end
end

def uas_request(%Message{} = sip_msg) do
  Logger.debug("dialog: no complete dialog id in request")
  uas_validate_request(sip_msg)
end
```

---

### **Location 6: Lines 340-367 (uas_response/2)**

```elixir
# CURRENT:
@spec uas_response(Message.t(), Message.t()) :: Message.t()
def uas_response(%Message{} = resp_sip_msg, %Message{} = req_sip_msg) do
  Logger.debug("dialog: uas_response #{inspect(resp_sip_msg)}")

  # Check if response creates or continues a dialog
  dialog_id = Dialog.from_message(resp_sip_msg)

  if Dialog.is_complete?(dialog_id) do
    dialog_id_str = Dialog.to_string(dialog_id)
    Logger.debug("dialog: dialog id #{inspect(dialog_id_str)} in response")

    case find_dialog(dialog_id_str) do
      {:error, :no_dialog} ->
        Logger.debug(
          "dialog #{uas_log_id(resp_sip_msg)}: dialog not found (dialog tracking not yet implemented)"
        )

        uas_maybe_create_dialog(resp_sip_msg, req_sip_msg)

      {:ok, dialog_pid} ->
        Logger.debug("dialog #{inspect(dialog_pid)}: found dialog")
        uas_pass_response(dialog_pid, resp_sip_msg, req_sip_msg)
    end
  else
    Logger.debug("dialog: no complete dialog id in response")
    resp_sip_msg
  end
end

# REFACTORED:
@spec uas_response(Message.t(), Message.t()) :: Message.t()
def uas_response(
      %Message{
        from: %{parameters: %{"tag" => from_tag}},
        to: %{parameters: %{"tag" => to_tag}},
        call_id: call_id
      } = resp_sip_msg,
      %Message{} = req_sip_msg
    ) do
  Logger.debug("dialog: uas_response #{inspect(resp_sip_msg)}")

  # For UAS: local=to_tag, remote=from_tag
  dialog_id_str = "#{call_id};local=#{to_tag};remote=#{from_tag};uas"
  Logger.debug("dialog: dialog id #{inspect(dialog_id_str)} in response")

  case find_dialog(dialog_id_str) do
    {:error, :no_dialog} ->
      Logger.debug(
        "dialog #{uas_log_id(resp_sip_msg)}: dialog not found (dialog tracking not yet implemented)"
      )
      uas_maybe_create_dialog(resp_sip_msg, req_sip_msg)

    {:ok, dialog_pid} ->
      Logger.debug("dialog #{inspect(dialog_pid)}: found dialog")
      uas_pass_response(dialog_pid, resp_sip_msg, req_sip_msg)
  end
end

def uas_response(%Message{} = resp_sip_msg, %Message{}) do
  Logger.debug("dialog: no complete dialog id in response")
  resp_sip_msg
end
```

---

### **Location 7: Lines 385-398 (uac_result/2)**

```elixir
# CURRENT:
@spec uac_result(Message.t(), trans_result()) :: :ok
def uac_result(%Message{} = out_req, trans_result) do
  # Extract dialog ID from the request
  dialog_id = Dialog.from_message(out_req)

  if Dialog.is_complete?(dialog_id) do
    dialog_id
    |> Dialog.to_string()
    |> find_dialog()
    |> handle_complete_dialog_lookup(out_req, trans_result)
  else
    handle_incomplete_dialog(out_req, trans_result)
  end
end

# REFACTORED:
@spec uac_result(Message.t(), trans_result()) :: :ok
def uac_result(
      %Message{
        from: %{parameters: %{"tag" => from_tag}},
        to: %{parameters: %{"tag" => to_tag}},
        call_id: call_id
      } = out_req,
      trans_result
    ) do
  # For UAC: local=from_tag (us), remote=to_tag (them)
  dialog_id_str = "#{call_id};local=#{from_tag};remote=#{to_tag};uac"

  dialog_id_str
  |> find_dialog()
  |> handle_complete_dialog_lookup(out_req, trans_result)
end

def uac_result(%Message{} = out_req, trans_result) do
  handle_incomplete_dialog(out_req, trans_result)
end
```

---

## Part 3: Replace Dialog.generate_id/4

### **Location 8: Lines 436-444 (handle_response_by_to_tag/3)**

```elixir
# CURRENT:
defp handle_response_by_to_tag(response_to_tag, out_req, response) do
  from_tag = get_from_tag(out_req)
  call_id = out_req.call_id
  complete_dialog_id_str = Dialog.generate_id(:uac, call_id, from_tag, response_to_tag)

  complete_dialog_id_str
  |> find_dialog()
  |> handle_dialog_lookup_for_response(out_req, response, complete_dialog_id_str)
end

# REFACTORED:
defp handle_response_by_to_tag(response_to_tag, out_req, response) do
  from_tag = get_from_tag(out_req)
  call_id = out_req.call_id
  # For UAC: local=from_tag, remote=to_tag
  dialog_id_str = "#{call_id};local=#{from_tag};remote=#{response_to_tag};uac"

  dialog_id_str
  |> find_dialog()
  |> handle_dialog_lookup_for_response(out_req, response, dialog_id_str)
end
```

---

### **Location 9: Lines 703-712 (via_tuple UAS)**

```elixir
# CURRENT:
defp via_tuple({:uas, resp_sip_msg, req_sip_msg}) do
  # UAS: Extract tags from request and response to build correct dialog ID
  from_tag = if req_sip_msg.from, do: req_sip_msg.from.parameters["tag"], else: nil
  to_tag = if resp_sip_msg.to, do: resp_sip_msg.to.parameters["tag"], else: nil
  call_id = req_sip_msg.call_id

  # For UAS: local=to_tag, remote=from_tag
  dialog_id_str = Dialog.generate_id(:uas, call_id, to_tag, from_tag)
  {:dialog, dialog_id_str}
end

# REFACTORED:
defp via_tuple({:uas,
    %Message{to: %{parameters: %{"tag" => to_tag}}},
    %Message{
      from: %{parameters: %{"tag" => from_tag}},
      call_id: call_id
    }}) do
  # For UAS: local=to_tag, remote=from_tag
  dialog_id_str = "#{call_id};local=#{to_tag};remote=#{from_tag};uas"
  {:dialog, dialog_id_str}
end
```

---

### **Location 10: Lines 714-723 (via_tuple UAC)**

```elixir
# CURRENT:
defp via_tuple({:uac, out_req, resp_sip_msg}) do
  # UAC: Extract tags from request and response to build correct dialog ID
  from_tag = if out_req.from, do: out_req.from.parameters["tag"], else: nil
  to_tag = if resp_sip_msg.to, do: resp_sip_msg.to.parameters["tag"], else: nil
  call_id = out_req.call_id

  # For UAC: local=from_tag, remote=to_tag
  dialog_id_str = Dialog.generate_id(:uac, call_id, from_tag, to_tag)
  {:dialog, dialog_id_str}
end

# REFACTORED:
defp via_tuple({:uac,
    %Message{
      from: %{parameters: %{"tag" => from_tag}},
      call_id: call_id
    },
    %Message{to: %{parameters: %{"tag" => to_tag}}}}) do
  # For UAC: local=from_tag, remote=to_tag
  dialog_id_str = "#{call_id};local=#{from_tag};remote=#{to_tag};uac"
  {:dialog, dialog_id_str}
end
```

---

## Part 4: Replace Message.get_header calls

### **Location 11: Lines 729-733 (uas_log_id/1)**

```elixir
# CURRENT:
defp uas_log_id(%Message{} = msg) do
  call_id = Message.get_header(msg, "call-id")
  method = msg.method
  "#{method} #{call_id}"
end

# REFACTORED:
defp uas_log_id(%Message{method: method, call_id: call_id}) do
  "#{method} #{call_id}"
end
```

---

### **Location 12: Lines 735-739 (uac_log_id/1)**

```elixir
# CURRENT:
defp uac_log_id(%Message{} = msg) do
  call_id = Message.get_header(msg, "call-id")
  method = if msg.type == :request, do: msg.method, else: "response"
  "#{method} #{call_id}"
end

# REFACTORED:
defp uac_log_id(%Message{type: :request, method: method, call_id: call_id}) do
  "#{method} #{call_id}"
end

defp uac_log_id(%Message{type: :response, call_id: call_id}) do
  "response #{call_id}"
end

defp uac_log_id(%Message{method: method, call_id: call_id}) do
  "#{method} #{call_id}"
end
```

---

### **Location 13: Lines 741-757 (get_expires/2)**

```elixir
# CURRENT:
defp get_expires(%Message{} = msg, default) do
  msg
  |> Message.get_header("expires")
  |> parse_expires_value(default)
end

defp parse_expires_value(nil, default), do: default
defp parse_expires_value(expires, _default) when is_integer(expires), do: expires
defp parse_expires_value(expires, default) when is_binary(expires), do: parse_expires_string(expires, default)
defp parse_expires_value(_other, default), do: default

defp parse_expires_string(expires, default) do
  case Integer.parse(expires) do
    {val, _} -> val
    :error -> default
  end
end

# REFACTORED (DELETE parse_expires_value and parse_expires_string):
defp get_expires(%Message{expires: expires}, _default) when is_integer(expires) do
  expires
end

defp get_expires(%Message{expires: expires}, default) when is_binary(expires) do
  case Integer.parse(expires) do
    {val, _} -> val
    :error -> default
  end
end

defp get_expires(%Message{}, default) do
  default
end
```

---

### **Location 14: Lines 759-770 (get_branch_from_request/1)**

```elixir
# CURRENT:
defp get_branch_from_request(%Message{} = request) do
  case Message.get_header(request, "via") do
    %Via{parameters: %{"branch" => branch}} ->
      branch

    [%Via{parameters: %{"branch" => branch}} | _] ->
      branch

    _ ->
      Branch.generate()
  end
end

# REFACTORED:
defp get_branch_from_request(%Message{via: %Via{parameters: %{"branch" => branch}}}) do
  branch
end

defp get_branch_from_request(%Message{via: [%Via{parameters: %{"branch" => branch}} | _]}) do
  branch
end

defp get_branch_from_request(%Message{}) do
  Branch.generate()
end
```

---

## Part 5: Refactor handle_message_result Pipeline (Lines 424-493)

### **Location 15: Complete Replacement**

```elixir
# CURRENT (DELETE ALL OF THIS):
defp handle_message_result(out_req, response) do
  response
  |> get_to_tag()
  |> handle_response_by_to_tag(out_req, response)
end

defp handle_response_by_to_tag(nil, _out_req, _response) do
  Logger.debug("dialog: response has no to-tag, not creating dialog")
  :ok
end

defp handle_response_by_to_tag(response_to_tag, out_req, response) do
  from_tag = get_from_tag(out_req)
  call_id = out_req.call_id
  complete_dialog_id_str = Dialog.generate_id(:uac, call_id, from_tag, response_to_tag)

  complete_dialog_id_str
  |> find_dialog()
  |> handle_dialog_lookup_for_response(out_req, response, complete_dialog_id_str)
end

# Helper to extract to-tag from response
defp get_to_tag(%Message{to: %{parameters: params}}) when is_map(params) do
  params["tag"]
end
defp get_to_tag(_), do: nil

# Helper to extract from-tag from request
defp get_from_tag(%Message{from: %{parameters: params}}) when is_map(params) do
  params["tag"]
end
defp get_from_tag(_), do: nil

# REFACTORED TO:
# Response has complete dialog info (both tags present)
defp handle_message_result(
    %Message{
      from: %{parameters: %{"tag" => from_tag}},
      call_id: call_id
    } = out_req,
    %Message{to: %{parameters: %{"tag" => to_tag}}} = response
  ) do
  # For UAC: local=from_tag, remote=to_tag
  dialog_id_str = "#{call_id};local=#{from_tag};remote=#{to_tag};uac"

  dialog_id_str
  |> find_dialog()
  |> handle_dialog_lookup_for_response(out_req, response, dialog_id_str)
end

# Response missing to-tag - cannot create dialog
defp handle_message_result(_out_req, _response) do
  Logger.debug("dialog: response has no to-tag, not creating dialog")
  :ok
end
```

**Note:** This eliminates `get_to_tag/1`, `get_from_tag/1`, and `handle_response_by_to_tag/3` entirely.

---

## Part 6: Refactor should_create_dialog?/2 (Lines 830-865)

### **Location 16: Complete Replacement**

```elixir
# CURRENT:
defp should_create_dialog?(%Message{status_code: status_code, to: %{parameters: to_params}}, %Message{method: method})
     when status_code >= 100 and status_code < 200 do
  # Early dialog: 1xx response to INVITE with to-tag
  method_atom = if is_binary(method), do: String.to_atom(String.downcase(method)), else: method
  has_to_tag = Map.has_key?(to_params, "tag")
  result = method_atom == :invite and has_to_tag

  Logger.debug(
    "should_create_dialog? early dialog: method=#{inspect(method)}, status=#{status_code}, has_to_tag=#{has_to_tag}, result=#{result}"
  )

  result
end

defp should_create_dialog?(%Message{status_code: status_code}, %Message{method: method})
     when status_code >= 200 and status_code < 300 do
  # Confirmed dialog: 2xx responses to INVITE or SUBSCRIBE
  method_atom = if is_binary(method), do: String.to_atom(String.downcase(method)), else: method
  result = method_atom in [:invite, :subscribe]

  Logger.debug(
    "should_create_dialog? confirmed: method=#{inspect(method)} (#{inspect(method_atom)}), status=#{status_code}, result=#{result}"
  )

  result
end

defp should_create_dialog?(resp, req) do
  Logger.debug(
    "should_create_dialog? no: resp status=#{inspect(resp.status_code)}, req method=#{inspect(req.method)}"
  )

  false
end

# REFACTORED TO:
# Early dialog: 1xx response to INVITE with to-tag
defp should_create_dialog?(
    %Message{status_code: code, to: %{parameters: %{"tag" => _}}},
    %Message{method: :invite}
  ) when code >= 100 and code < 200 do
  Logger.debug("should_create_dialog? early dialog: INVITE 1xx with to-tag")
  true
end

# Confirmed dialog: 2xx response to INVITE or SUBSCRIBE
defp should_create_dialog?(
    %Message{status_code: code},
    %Message{method: method}
  ) when code >= 200 and code < 300 and method in [:invite, :subscribe] do
  Logger.debug("should_create_dialog? confirmed: #{method} 2xx")
  true
end

# All other cases - no dialog
defp should_create_dialog?(%Message{status_code: code}, %Message{method: method}) do
  Logger.debug("should_create_dialog? no: status=#{code}, method=#{method}")
  false
end
```

---

## Part 7: Minor Updates to init/1 (Lines 198-200)

### **Location 17: Line 200**

```elixir
# CURRENT:
req_method = req_sip_msg.method
res_method = resp_sip_msg.method
call_id = Message.get_header(req_sip_msg, "call-id")

# REFACTORED:
req_method = req_sip_msg.method
res_method = resp_sip_msg.method
call_id = req_sip_msg.call_id
```

---

## Summary of Functions to DELETE

After this refactoring, **delete these 10 functions**:

### **From dialog_statem.ex:**
1. `get_to_tag/1` (lines 484-487)
2. `get_from_tag/1` (lines 490-493)
3. `parse_expires_value/2` (lines 747-750)
4. `parse_expires_string/2` (lines 752-757)
5. `handle_response_by_to_tag/3` (lines 431-444)

### **From dialog.ex:**
6. `Dialog.from_message/1` (lines 435-487)
7. `Dialog.is_complete?/1` (lines 502-509)
8. `Dialog.to_string/1` (lines 527-540)
9. `Dialog.generate_id/4` (lines 765-774)
10. `Dialog.is_early?/1` (lines 1045-1048)

---

## Testing Strategy

After each change:
1. Run the full test suite: `mix test`
2. Test dialog creation scenarios (UAS and UAC)
3. Test dialog lookup with complete/incomplete IDs
4. Verify early → confirmed → terminated state transitions
5. Test INVITE and SUBSCRIBE dialog types

---

## Implementation Order (Recommended)

1. **Phase 1** (Low Risk): Locations 11-14 (Message.get_header replacements)
2. **Phase 2** (Low Risk): Locations 1-3 (Dialog.is_early? replacements)
3. **Phase 3** (Medium Risk): Locations 8-10 (Dialog.generate_id replacements)
4. **Phase 4** (Medium Risk): Location 16 (should_create_dialog? refactor)
5. **Phase 5** (Higher Risk): Locations 4-7 (Dialog.from_message/is_complete/to_string replacements)
6. **Phase 6** (Medium Risk): Location 15 (handle_message_result pipeline)
7. **Phase 7**: Delete unused functions and run full tests

This order minimizes risk by starting with simple changes and building up to the more complex refactorings.

---

## Rationale

### Why This Refactoring?

1. **Performance**: Eliminates intermediate map allocations and function call overhead
2. **Readability**: Pattern matching makes requirements explicit in function signatures
3. **Type Safety**: Pattern match failures surface immediately at compile time
4. **Idiomatic Elixir**: Uses the BEAM's strength - pattern matching over helper functions
5. **Maintainability**: Less code to maintain, clearer intent

### Key Principles

- **Parse once, trust everywhere**: Methods are normalized at parse time to lowercase atoms
- **Pattern matching over extraction**: Function signatures document requirements
- **Multi-clause definitions over conditionals**: Let the VM do the work
- **Guards for constraints**: Move logic into the type system where possible

---

## Notes

- All incoming messages from the parser have methods as lowercase atoms (`:invite`, `:bye`, etc.)
- Dialog IDs follow format: `"#{call_id};local=#{local_tag};remote=#{remote_tag};#{direction}"`
- UAS perspective: local=to_tag (us), remote=from_tag (them)
- UAC perspective: local=from_tag (us), remote=to_tag (them)
