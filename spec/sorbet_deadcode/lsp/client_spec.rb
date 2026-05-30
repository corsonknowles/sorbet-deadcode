# frozen_string_literal: true

require_relative "../../spec_helper"
require "open3"

module SorbetDeadcode
  module Lsp
    class ClientSpec < Minitest::Test
      # A stand-in for the Process::Waiter returned by Open3.popen3.
      class FakeWaitThread
        attr_reader :pid

        def initialize(alive:)
          @alive = alive
          @pid = 424_242
        end

        def join(_timeout = nil)
          self
        end

        def alive?
          @alive
        end
      end

      def test_initialize_spawns_server_and_handshakes
        dir = Dir.mktmpdir
        FileUtils.mkdir_p(File.join(dir, "tmp", "cache", "sorbet"))

        stdin_read, stdin_write = IO.pipe
        stdout_read, stdout_write = IO.pipe

        responder = Thread.new do
          write_lsp_message(stdout_write, { "jsonrpc" => "2.0", "id" => 1, "result" => { "capabilities" => {} } })
        rescue IOError, Errno::EPIPE
          nil
        end
        drainer = Thread.new { stdin_read.read rescue nil }

        client = nil
        Open3.stub(:popen3, [stdin_write, stdout_read, nil, FakeWaitThread.new(alive: false)]) do
          suppress_stderr { client = Client.new(dir) }
        end

        assert_equal File.expand_path(dir), client.project_root
        responder.join
        stdout_write.close
        stdin_write.close
        drainer.join
      ensure
        FileUtils.remove_entry(dir) if dir
      end

      def test_shutdown_when_started_closes_streams
        client = build_started_client(wait_thread: FakeWaitThread.new(alive: false))
        suppress_stderr { client.shutdown }
        # A second shutdown is a no-op because @started is now false.
        client.shutdown
      end

      def test_shutdown_kills_lingering_process
        client = build_started_client(wait_thread: FakeWaitThread.new(alive: true))
        killed = []
        Process.stub(:kill, ->(sig, pid) { killed << [sig, pid] }) do
          suppress_stderr { client.shutdown }
        end
        assert_equal [["TERM", 424_242]], killed
      end

      def test_shutdown_rescues_already_exited_process
        client = build_started_client(wait_thread: FakeWaitThread.new(alive: true))
        Process.stub(:kill, ->(_sig, _pid) { raise Errno::ESRCH }) do
          suppress_stderr { client.shutdown }
        end
      end

      def test_close_streams_with_nil_fields_is_safe
        client = Client.allocate
        client.instance_variable_set(:@stdin, nil)
        client.instance_variable_set(:@stdout, nil)
        client.instance_variable_set(:@stderr_thread, nil)
        client.instance_variable_set(:@wait_thread, nil)
        # No crash — all &. branches take the nil path.
        client.send(:close_streams)
      end

      def test_did_open_is_idempotent
        dir = Dir.mktmpdir
        test_file = File.join(dir, "test.rb")
        File.write(test_file, "class Foo; end")

        suppress_stderr do
          client = build_mock_client(dir, cache_exists: false, references_result: [])
          # First call opens the file, second call is a no-op (already in @opened_files).
          client.references(test_file, 0, 6)
          client.references(test_file, 0, 6)
        end
      ensure
        FileUtils.remove_entry(dir) if dir
      end

      def test_read_response_raises_on_buffered_error
        dir = Dir.mktmpdir
        test_file = File.join(dir, "test.rb")
        File.write(test_file, "class Foo; end")

        suppress_stderr do
          client = build_mock_client(dir, cache_exists: false, references_result: [])
          # Pre-buffer an error response for a future expected_id.
          client.instance_variable_get(:@buffered_responses)[99] =
            { "id" => 99, "error" => { "message" => "buffered boom" } }
          assert_raises(Client::Error) { client.send(:read_response, 99) }
        end
      ensure
        FileUtils.remove_entry(dir) if dir
      end

      def test_read_response_buffers_out_of_order_message_then_returns_it
        dir = Dir.mktmpdir
        test_file = File.join(dir, "test.rb")
        File.write(test_file, "class Foo; end")

        suppress_stderr do
          # The mock sends: initialize(id=1), then refs(id=3) before refs(id=2).
          # We request id=2 first; the loop should buffer id=3, then see id=2.
          client = build_mock_client(dir, cache_exists: false,
            extra_responses: [
              { "jsonrpc" => "2.0", "id" => 3, "result" => ["extra"] },
              { "jsonrpc" => "2.0", "id" => 2, "result" => [] },
            ])
          refs = client.references(test_file, 0, 6)
          assert_equal [], refs
          # id=3 is now buffered
          assert_equal ["extra"], client.send(:read_response, 3)
        end
      ensure
        FileUtils.remove_entry(dir) if dir
      end

      def test_read_response_returns_nil_when_stream_closes_mid_loop
        stdin_read, stdin_write = IO.pipe
        stdout_read, stdout_write = IO.pipe

        # Close the write end immediately so gets returns nil.
        stdout_write.close

        client = Client.allocate
        client.instance_variable_set(:@stdin, stdin_write)
        client.instance_variable_set(:@stdout, stdout_read)

        result = client.send(:read_response, 42)
        assert_nil result
      ensure
        stdin_read.close rescue nil
        stdin_write.close rescue nil
        stdout_read.close rescue nil
      end

      def test_read_message_returns_nil_when_stdout_closed
        stdin_read, stdin_write = IO.pipe
        stdout_read, stdout_write = IO.pipe
        stdout_write.close   # nothing to read

        client = Client.allocate
        client.instance_variable_set(:@stdout, stdout_read)
        result = client.send(:read_message)
        assert_nil result
      ensure
        stdin_read.close rescue nil
        stdin_write.close rescue nil
        stdout_read.close rescue nil
      end

      def test_read_message_returns_nil_with_no_content_length_header
        stdin_read, stdin_write = IO.pipe
        stdout_read, stdout_write = IO.pipe

        Thread.new do
          # Write a header-less blank terminator so the loop breaks without a length.
          stdout_write.write("X-Unknown-Header: foo\r\n\r\n")
          stdout_write.close
        rescue IOError
          nil
        end

        client = Client.allocate
        client.instance_variable_set(:@stdout, stdout_read)
        result = client.send(:read_message)
        assert_nil result
      ensure
        stdin_read.close rescue nil
        stdin_write.close rescue nil
        stdout_read.close rescue nil
      end

      def test_read_message_returns_nil_on_empty_body
        stdin_read, stdin_write = IO.pipe
        stdout_read, stdout_write = IO.pipe

        Thread.new do
          stdout_write.write("Content-Length: 0\r\n\r\n")
          stdout_write.close
        rescue IOError
          nil
        end

        client = Client.allocate
        client.instance_variable_set(:@stdout, stdout_read)
        result = client.send(:read_message)
        assert_nil result
      ensure
        stdin_read.close rescue nil
        stdin_write.close rescue nil
        stdout_read.close rescue nil
      end

      def test_notification_from_server_is_buffered_and_skipped
        dir = Dir.mktmpdir
        test_file = File.join(dir, "test.rb")
        File.write(test_file, "class Foo; end")

        # Insert a server-push notification (no "id") before the actual response.
        suppress_stderr do
          client = build_mock_client(dir, cache_exists: false,
            extra_responses: [
              { "jsonrpc" => "2.0", "method" => "window/showMessage", "params" => {} },
              { "jsonrpc" => "2.0", "id" => 2, "result" => [] },
            ])
          refs = client.references(test_file, 0, 6)
          assert_equal [], refs
        end
      ensure
        FileUtils.remove_entry(dir) if dir
      end

      def test_references_raises_on_lsp_error
        dir = Dir.mktmpdir
        test_file = File.join(dir, "test.rb")
        File.write(test_file, "class Foo; end")

        suppress_stderr do
          client = build_mock_client(dir, cache_exists: false, error_response: { "message" => "boom" })
          assert_raises(Client::Error) { client.references(test_file, 0, 6) }
        end
      ensure
        FileUtils.remove_entry(dir) if dir
      end

      def test_read_message_skips_leading_blank_lines
        dir = Dir.mktmpdir
        test_file = File.join(dir, "test.rb")
        File.write(test_file, "class Foo; end")

        refs = nil
        suppress_stderr do
          client = build_mock_client(dir, cache_exists: false, references_result: [], leading_blank: true)
          refs = client.references(test_file, 0, 6)
        end
        assert_equal [], refs
      ensure
        FileUtils.remove_entry(dir) if dir
      end
      def test_warns_when_sorbet_cache_missing
        dir = Dir.mktmpdir

        warning = capture_stderr do
          _client = build_mock_client(dir, cache_exists: false)
        end

        assert_match(/Sorbet cache not found/, warning)
        assert_match(/tmp\/cache\/sorbet/, warning)
      end

      def test_no_warning_when_sorbet_cache_exists
        dir = Dir.mktmpdir
        FileUtils.mkdir_p(File.join(dir, "tmp", "cache", "sorbet"))

        warning = capture_stderr do
          _client = build_mock_client(dir, cache_exists: true)
        end

        assert_empty warning
      ensure
        FileUtils.remove_entry(dir) if dir
      end

      def test_references_returns_array
        dir = Dir.mktmpdir
        test_file = File.join(dir, "test.rb")
        File.write(test_file, "class Foo; end")

        refs = nil
        suppress_stderr do
          client = build_mock_client(dir, cache_exists: false, references_result: [
            { "uri" => "file://#{test_file}", "range" => { "start" => { "line" => 5, "character" => 0 } } },
          ])
          refs = client.references(test_file, 0, 6)
        end

        assert_kind_of Array, refs
      ensure
        FileUtils.remove_entry(dir) if dir
      end

      def test_references_returns_empty_for_no_refs
        dir = Dir.mktmpdir
        test_file = File.join(dir, "test.rb")
        File.write(test_file, "class Foo; end")

        refs = nil
        suppress_stderr do
          client = build_mock_client(dir, cache_exists: false, references_result: [])
          refs = client.references(test_file, 0, 6)
        end

        assert_equal [], refs
      ensure
        FileUtils.remove_entry(dir) if dir
      end

      def test_shutdown_is_safe_when_not_started
        client = Client.allocate
        client.instance_variable_set(:@started, false)
        client.shutdown
      end

      private

      # Builds a Client with mocked I/O so we never start a real Sorbet process
      def build_mock_client(project_root, cache_exists: false, references_result: [], error_response: nil, leading_blank: false, extra_responses: nil)
        client = Client.allocate
        client.instance_variable_set(:@project_root, File.expand_path(project_root))
        client.instance_variable_set(:@request_id, 0)
        client.instance_variable_set(:@started, false)
        client.instance_variable_set(:@opened_files, Set.new)

        # Run cache check (may print warning)
        client.send(:check_sorbet_cache)

        # Set up mock I/O
        stdin_read, stdin_write = IO.pipe
        stdout_read, stdout_write = IO.pipe

        client.instance_variable_set(:@stdin, stdin_write)
        client.instance_variable_set(:@stdout, stdout_read)
        client.instance_variable_set(:@stderr_thread, nil)
        client.instance_variable_set(:@wait_thread, nil)
        client.instance_variable_set(:@started, true)

        # Provide mock responses in a background thread:
        # 1. initialize response
        # 2. references response (if requested)
        Thread.new do
          # Respond to initialize (id=1)
          write_lsp_message(stdout_write, { "jsonrpc" => "2.0", "id" => 1, "result" => { "capabilities" => {} } })

          # Optionally exercise the blank-line skip in read_message
          stdout_write.write("\r\n") if leading_blank

          if extra_responses
            # Caller provides the full sequence after initialize.
            extra_responses.each { |m| write_lsp_message(stdout_write, m) }
          elsif error_response
            write_lsp_message(stdout_write, { "jsonrpc" => "2.0", "id" => 2, "error" => error_response })
          else
            write_lsp_message(stdout_write, { "jsonrpc" => "2.0", "id" => 2, "result" => references_result })
            # Second references call (same file — idempotent did_open):
            write_lsp_message(stdout_write, { "jsonrpc" => "2.0", "id" => 3, "result" => [] })
          end

          # Respond to shutdown
          write_lsp_message(stdout_write, { "jsonrpc" => "2.0", "id" => 10, "result" => nil })
        rescue IOError, Errno::EPIPE
          # Pipe closed, that's fine
        end

        # Send initialize + initialized
        client.send(:send_initialize)
        client.send(:send_initialized)

        # Drain stdin so the pipe doesn't block
        Thread.new { stdin_read.read rescue nil }

        client
      end

      # Builds a "started" client (no handshake) with a responder that answers the
      # next request (the shutdown request, id=1).
      def build_started_client(wait_thread:)
        client = Client.allocate
        client.instance_variable_set(:@project_root, "/tmp")
        client.instance_variable_set(:@request_id, 0)
        client.instance_variable_set(:@opened_files, Set.new)

        stdin_read, stdin_write = IO.pipe
        stdout_read, stdout_write = IO.pipe

        client.instance_variable_set(:@stdin, stdin_write)
        client.instance_variable_set(:@stdout, stdout_read)
        client.instance_variable_set(:@stderr_thread, FakeWaitThread.new(alive: false))
        client.instance_variable_set(:@wait_thread, wait_thread)
        client.instance_variable_set(:@started, true)

        Thread.new do
          write_lsp_message(stdout_write, { "jsonrpc" => "2.0", "id" => 1, "result" => nil })
        rescue IOError, Errno::EPIPE
          nil
        end
        Thread.new { stdin_read.read rescue nil }

        client
      end

      def write_lsp_message(io, message)
        json = JSON.generate(message)
        io.write("Content-Length: #{json.bytesize}\r\n\r\n")
        io.write(json)
        io.flush
      end

      def capture_stderr
        original = $stderr
        $stderr = StringIO.new
        yield
        $stderr.string
      ensure
        $stderr = original
      end

      def suppress_stderr
        original = $stderr
        $stderr = StringIO.new
        yield
      ensure
        $stderr = original
      end
    end
  end
end
