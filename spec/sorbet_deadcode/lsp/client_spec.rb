# frozen_string_literal: true

require_relative "../../spec_helper"

module SorbetDeadcode
  module Lsp
    class ClientSpec < Minitest::Test
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
      def build_mock_client(project_root, cache_exists: false, references_result: [])
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

          # Respond to references (id=2)
          write_lsp_message(stdout_write, { "jsonrpc" => "2.0", "id" => 2, "result" => references_result })

          # Respond to shutdown (id=3)
          write_lsp_message(stdout_write, { "jsonrpc" => "2.0", "id" => 3, "result" => nil })
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
