defmodule A2aRelay.MailboxTest do
  use ExUnit.Case, async: false

  alias A2aRelay.Mailbox

  setup do
    if :ets.whereis(:mailbox) != :undefined do
      :ets.delete_all_objects(:mailbox)
    end

    :ok
  end

  describe "enqueue/4 and drain/2" do
    test "enqueues and drains messages" do
      assert :ok = Mailbox.enqueue("t1", "a1", "message/send", %{"text" => "hello"})
      assert :ok = Mailbox.enqueue("t1", "a1", "message/send", %{"text" => "world"})

      messages = Mailbox.drain("t1", "a1")
      assert length(messages) == 2
      assert Enum.at(messages, 0).method == "message/send"
      assert Enum.at(messages, 0).params == %{"text" => "hello"}
      assert Enum.at(messages, 1).params == %{"text" => "world"}
    end

    test "drain returns empty list for no messages" do
      assert [] = Mailbox.drain("t1", "nonexistent")
    end

    test "drain removes messages from mailbox" do
      Mailbox.enqueue("t1", "a1", "test", %{})
      assert [_] = Mailbox.drain("t1", "a1")
      assert [] = Mailbox.drain("t1", "a1")
    end

    test "messages are in FIFO order" do
      for i <- 1..5 do
        # Small sleep to ensure distinct timestamps
        Process.sleep(1)
        Mailbox.enqueue("t1", "a1", "method_#{i}", %{"i" => i})
      end

      messages = Mailbox.drain("t1", "a1")
      methods = Enum.map(messages, & &1.method)
      assert methods == ["method_1", "method_2", "method_3", "method_4", "method_5"]
    end
  end

  describe "queue_depth/2" do
    test "returns correct depth" do
      assert Mailbox.queue_depth("t1", "a1") == 0

      Mailbox.enqueue("t1", "a1", "test", %{})
      assert Mailbox.queue_depth("t1", "a1") == 1

      Mailbox.enqueue("t1", "a1", "test", %{})
      assert Mailbox.queue_depth("t1", "a1") == 2
    end

    test "is per-agent" do
      Mailbox.enqueue("t1", "a1", "test", %{})
      Mailbox.enqueue("t1", "a2", "test", %{})

      assert Mailbox.queue_depth("t1", "a1") == 1
      assert Mailbox.queue_depth("t1", "a2") == 1
    end
  end

  describe "max messages limit" do
    test "rejects when mailbox is full" do
      # Temporarily set a low limit
      original = Application.get_env(:a2a_relay, :max_mailbox_messages)
      Application.put_env(:a2a_relay, :max_mailbox_messages, 3)

      on_exit(fn ->
        if original do
          Application.put_env(:a2a_relay, :max_mailbox_messages, original)
        end
      end)

      assert :ok = Mailbox.enqueue("t1", "full", "m1", %{})
      assert :ok = Mailbox.enqueue("t1", "full", "m2", %{})
      assert :ok = Mailbox.enqueue("t1", "full", "m3", %{})
      assert {:error, :mailbox_full} = Mailbox.enqueue("t1", "full", "m4", %{})
    end
  end
end
