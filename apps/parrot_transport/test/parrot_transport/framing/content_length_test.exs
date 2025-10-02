defmodule ParrotTransport.Framing.ContentLengthTest do
  use ExUnit.Case, async: true

  alias ParrotTransport.Framing.ContentLength

  describe "find_header_end/1" do
    test "finds headers ending with CRLF CRLF" do
      buffer = "INVITE sip:bob@example.com SIP/2.0\r\nContent-Length: 0\r\n\r\n"

      assert {:ok, headers, body_pos} = ContentLength.find_header_end(buffer)
      assert headers == buffer
      assert body_pos == byte_size(buffer)
    end

    test "returns incomplete when no double CRLF" do
      buffer = "INVITE sip:bob@example.com SIP/2.0\r\nContent-Length: 0\r\n"
      assert :incomplete = ContentLength.find_header_end(buffer)
    end

    test "handles empty buffer" do
      assert :incomplete = ContentLength.find_header_end("")
    end

    test "handles single CRLF" do
      assert :incomplete = ContentLength.find_header_end("\r\n")
    end

    test "finds CRLF CRLF in middle of buffer" do
      buffer = "INVITE sip:bob@example.com SIP/2.0\r\n\r\nBODY DATA HERE"

      assert {:ok, headers, body_pos} = ContentLength.find_header_end(buffer)
      assert headers == "INVITE sip:bob@example.com SIP/2.0\r\n\r\n"
      # body_pos is where body starts (after the \r\n\r\n)
      assert body_pos == 38
    end
  end

  describe "extract_content_length/1" do
    test "extracts valid Content-Length" do
      headers = "INVITE sip:bob SIP/2.0\r\nContent-Length: 142\r\n\r\n"
      assert {:ok, 142} = ContentLength.extract_content_length(headers)
    end

    test "returns 0 when no Content-Length header" do
      headers = "INVITE sip:bob SIP/2.0\r\n\r\n"
      assert {:ok, 0} = ContentLength.extract_content_length(headers)
    end

    test "handles case-insensitive header name" do
      headers = "INVITE sip:bob SIP/2.0\r\ncontent-length: 100\r\n\r\n"
      assert {:ok, 100} = ContentLength.extract_content_length(headers)

      headers = "INVITE sip:bob SIP/2.0\r\nCONTENT-LENGTH: 200\r\n\r\n"
      assert {:ok, 200} = ContentLength.extract_content_length(headers)
    end

    test "handles whitespace around value" do
      headers = "INVITE sip:bob SIP/2.0\r\nContent-Length:   123   \r\n\r\n"
      assert {:ok, 123} = ContentLength.extract_content_length(headers)
    end

    test "returns error for invalid Content-Length value" do
      headers = "INVITE sip:bob SIP/2.0\r\nContent-Length: invalid\r\n\r\n"
      assert {:error, :invalid_content_length} = ContentLength.extract_content_length(headers)
    end

    test "returns error for negative Content-Length" do
      headers = "INVITE sip:bob SIP/2.0\r\nContent-Length: -100\r\n\r\n"
      assert {:error, :invalid_content_length} = ContentLength.extract_content_length(headers)
    end

    test "handles Content-Length: 0" do
      headers = "INVITE sip:bob SIP/2.0\r\nContent-Length: 0\r\n\r\n"
      assert {:ok, 0} = ContentLength.extract_content_length(headers)
    end
  end

  describe "process/2 - single complete message" do
    test "extracts message with no body" do
      framing = %ContentLength{}
      message = "INVITE sip:bob SIP/2.0\r\nContent-Length: 0\r\n\r\n"

      assert {:ok, [^message], new_framing} = ContentLength.process(framing, message)
      assert new_framing.buffer == <<>>
      assert new_framing.state == :seeking_headers
    end

    test "extracts message with body" do
      framing = %ContentLength{}
      body = "v=0\r\no=alice 123 456 IN IP4 127.0.0.1\r\n"
      message = "INVITE sip:bob SIP/2.0\r\nContent-Length: #{byte_size(body)}\r\n\r\n#{body}"

      assert {:ok, [^message], new_framing} = ContentLength.process(framing, message)
      assert new_framing.buffer == <<>>
    end

    test "extracts message with exact body length" do
      framing = %ContentLength{}
      body = "12345678901234567890"
      message = "INVITE sip:bob SIP/2.0\r\nContent-Length: 20\r\n\r\n#{body}"

      assert {:ok, [^message], _} = ContentLength.process(framing, message)
    end
  end

  describe "process/2 - multiple messages" do
    test "extracts two complete messages in one buffer" do
      framing = %ContentLength{}
      msg1 = "INVITE sip:bob SIP/2.0\r\nContent-Length: 0\r\n\r\n"
      msg2 = "BYE sip:bob SIP/2.0\r\nContent-Length: 0\r\n\r\n"

      assert {:ok, [^msg1, ^msg2], new_framing} = ContentLength.process(framing, msg1 <> msg2)
      assert new_framing.buffer == <<>>
    end

    test "extracts three messages in one buffer" do
      framing = %ContentLength{}
      msg1 = "INVITE sip:bob SIP/2.0\r\nContent-Length: 0\r\n\r\n"
      msg2 = "ACK sip:bob SIP/2.0\r\nContent-Length: 0\r\n\r\n"
      msg3 = "BYE sip:bob SIP/2.0\r\nContent-Length: 0\r\n\r\n"

      assert {:ok, messages, _} = ContentLength.process(framing, msg1 <> msg2 <> msg3)
      assert messages == [msg1, msg2, msg3]
    end

    test "extracts messages with bodies" do
      framing = %ContentLength{}
      body1 = "BODY1"
      body2 = "BODY2"
      msg1 = "INVITE sip:bob SIP/2.0\r\nContent-Length: #{byte_size(body1)}\r\n\r\n#{body1}"
      msg2 = "BYE sip:bob SIP/2.0\r\nContent-Length: #{byte_size(body2)}\r\n\r\n#{body2}"

      assert {:ok, [^msg1, ^msg2], _} = ContentLength.process(framing, msg1 <> msg2)
    end
  end

  describe "process/2 - partial messages" do
    test "buffers partial headers" do
      framing = %ContentLength{}
      partial = "INVITE sip:bob SIP/2.0\r\nCont"

      assert {:ok, [], new_framing} = ContentLength.process(framing, partial)
      assert new_framing.buffer == partial
      assert new_framing.state == :seeking_headers
    end

    test "completes headers on second chunk" do
      framing = %ContentLength{}
      chunk1 = "INVITE sip:bob SIP/2.0\r\nCont"
      chunk2 = "ent-Length: 0\r\n\r\n"

      {:ok, [], framing2} = ContentLength.process(framing, chunk1)
      assert {:ok, [message], _} = ContentLength.process(framing2, chunk2)
      assert message == chunk1 <> chunk2
    end

    test "buffers partial body" do
      framing = %ContentLength{}
      chunk1 = "INVITE sip:bob SIP/2.0\r\nContent-Length: 10\r\n\r\n123"

      assert {:ok, [], new_framing} = ContentLength.process(framing, chunk1)
      assert new_framing.state == {:reading_body, 10}
      assert new_framing.buffer == "123"
    end

    test "completes body across multiple chunks" do
      framing = %ContentLength{}
      chunk1 = "INVITE sip:bob SIP/2.0\r\nContent-Length: 10\r\n\r\n12"
      chunk2 = "34"
      chunk3 = "567890"

      {:ok, [], framing2} = ContentLength.process(framing, chunk1)
      {:ok, [], framing3} = ContentLength.process(framing2, chunk2)
      assert {:ok, [message], _} = ContentLength.process(framing3, chunk3)

      expected = "INVITE sip:bob SIP/2.0\r\nContent-Length: 10\r\n\r\n1234567890"
      assert message == expected
    end

    test "handles message split at CRLF boundary" do
      framing = %ContentLength{}
      chunk1 = "INVITE sip:bob SIP/2.0\r\nContent-Length: 0\r\n\r"
      chunk2 = "\n"

      {:ok, [], framing2} = ContentLength.process(framing, chunk1)
      assert {:ok, [message], _} = ContentLength.process(framing2, chunk2)
      assert message == chunk1 <> chunk2
    end
  end

  describe "process/2 - edge cases" do
    test "handles empty input" do
      framing = %ContentLength{}
      assert {:ok, [], ^framing} = ContentLength.process(framing, "")
    end

    test "handles single byte at a time" do
      framing = %ContentLength{}
      message = "INVITE sip:bob SIP/2.0\r\nContent-Length: 0\r\n\r\n"

      {final_framing, all_messages} =
        message
        |> String.graphemes()
        |> Enum.reduce({framing, []}, fn byte, {current_framing, acc_messages} ->
          {:ok, new_messages, new_framing} = ContentLength.process(current_framing, byte)
          {new_framing, acc_messages ++ new_messages}
        end)

      assert all_messages == [message]
      assert final_framing.buffer == <<>>
    end

    test "handles very large body" do
      framing = %ContentLength{}
      body = String.duplicate("A", 100_000)
      message = "INVITE sip:bob SIP/2.0\r\nContent-Length: #{byte_size(body)}\r\n\r\n#{body}"

      assert {:ok, [^message], _} = ContentLength.process(framing, message)
    end

    test "handles partial then complete message in next chunk" do
      framing = %ContentLength{}
      chunk1 = "INVITE sip:bob SIP/2.0\r\nContent-Length: 5\r\n\r\n12"
      msg2 = "BYE sip:bob SIP/2.0\r\nContent-Length: 0\r\n\r\n"
      chunk2 = "345" <> msg2

      {:ok, [], framing2} = ContentLength.process(framing, chunk1)
      assert {:ok, messages, _} = ContentLength.process(framing2, chunk2)

      expected_msg1 = "INVITE sip:bob SIP/2.0\r\nContent-Length: 5\r\n\r\n12345"
      assert messages == [expected_msg1, msg2]
    end
  end

  describe "process/2 - realistic TCP scenarios" do
    test "message arrives in random chunk sizes" do
      message = "INVITE sip:bob@example.com SIP/2.0\r\n" <>
                "Content-Length: 50\r\n\r\n" <>
                String.duplicate("X", 50)

      # Test with specific chunk sizes
      test_chunks = fn chunks ->
        framing = %ContentLength{}

        {final_framing, all_messages} =
          Enum.reduce(chunks, {framing, []}, fn chunk, {current_framing, acc_messages} ->
            {:ok, new_messages, new_framing} = ContentLength.process(current_framing, chunk)
            {new_framing, acc_messages ++ new_messages}
          end)

        {all_messages, final_framing}
      end

      # Split message in half
      mid = div(byte_size(message), 2)
      chunk1 = binary_part(message, 0, mid)
      chunk2 = binary_part(message, mid, byte_size(message) - mid)
      {msgs, framing} = test_chunks.([chunk1, chunk2])
      assert msgs == [message]
      assert framing.buffer == <<>>

      # Split into small chunks
      small_chunks = for i <- 0..(byte_size(message)-1)//10 do
        remaining = byte_size(message) - i
        size = min(10, remaining)
        binary_part(message, i, size)
      end
      {msgs2, framing2} = test_chunks.(small_chunks)
      assert msgs2 == [message]
      assert framing2.buffer == <<>>

      # Whole message at once
      {msgs3, framing3} = test_chunks.([message])
      assert msgs3 == [message]
      assert framing3.buffer == <<>>
    end

    test "multiple messages with varying body sizes" do
      framing = %ContentLength{}

      messages = [
        "INVITE sip:bob SIP/2.0\r\nContent-Length: 0\r\n\r\n",
        "ACK sip:bob SIP/2.0\r\nContent-Length: 10\r\n\r\n1234567890",
        "BYE sip:bob SIP/2.0\r\nContent-Length: 5\r\n\r\nABCDE",
        "CANCEL sip:bob SIP/2.0\r\nContent-Length: 0\r\n\r\n"
      ]

      concatenated = Enum.join(messages, "")

      assert {:ok, extracted, final_framing} = ContentLength.process(framing, concatenated)
      assert extracted == messages
      assert final_framing.buffer == <<>>
    end
  end
end
