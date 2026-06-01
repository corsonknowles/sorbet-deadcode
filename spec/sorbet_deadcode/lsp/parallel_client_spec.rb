# frozen_string_literal: true

require_relative "../../spec_helper"

module SorbetDeadcode
  module Lsp
    class ParallelClientSpec < Minitest::Test
      def test_async_references_returns_request_id
        dir = Dir.mktmpdir
        test_file = File.join(dir, "test.rb")
        File.write(test_file, "class Foo; end")

        suppress_stderr do
          client = build_async_mock_client(dir, responses: {
                                             2 => [{ "uri" => "file://#{test_file}", "range" => { "start" => { "line" => 5, "character" => 0 } } }] # rubocop:disable Layout/LineLength
                                           })
          id = client.async_references(test_file, 0, 6)
          assert_kind_of Integer, id
        end
      ensure
        FileUtils.remove_entry(dir) if dir
      end

      def test_collect_response_returns_result_for_id
        dir = Dir.mktmpdir
        test_file = File.join(dir, "test.rb")
        File.write(test_file, "class Foo; end")

        suppress_stderr do
          expected_refs = [
            { "uri" => "file://#{test_file}", "range" => { "start" => { "line" => 5, "character" => 0 } } }
          ]
          client = build_async_mock_client(dir, responses: {
                                             2 => expected_refs
                                           })
          id = client.async_references(test_file, 0, 6)
          result = client.collect_response(id)
          assert_equal expected_refs, result
        end
      ensure
        FileUtils.remove_entry(dir) if dir
      end

      def test_multiple_async_requests_tracked_by_id
        dir = Dir.mktmpdir
        file_a = File.join(dir, "a.rb")
        file_b = File.join(dir, "b.rb")
        File.write(file_a, "class A; end")
        File.write(file_b, "class B; end")

        suppress_stderr do
          refs_a = [{ "uri" => "file://#{file_a}", "range" => { "start" => { "line" => 1, "character" => 0 } } }]
          refs_b = [{ "uri" => "file://#{file_b}", "range" => { "start" => { "line" => 2, "character" => 0 } } }]

          client = build_async_mock_client(dir, responses: {
                                             2 => refs_a,
                                             3 => refs_b
                                           })

          id_a = client.async_references(file_a, 0, 6)
          id_b = client.async_references(file_b, 0, 6)

          refute_equal id_a, id_b

          result_a = client.collect_response(id_a)
          result_b = client.collect_response(id_b)

          assert_equal refs_a, result_a
          assert_equal refs_b, result_b
        end
      ensure
        FileUtils.remove_entry(dir) if dir
      end

      def test_out_of_order_responses_are_buffered
        dir = Dir.mktmpdir
        file_a = File.join(dir, "a.rb")
        file_b = File.join(dir, "b.rb")
        File.write(file_a, "class A; end")
        File.write(file_b, "class B; end")

        suppress_stderr do
          refs_a = [{ "uri" => "file://x", "range" => { "start" => { "line" => 1, "character" => 0 } } }]
          refs_b = [{ "uri" => "file://y", "range" => { "start" => { "line" => 2, "character" => 0 } } }]

          # Responses arrive in reverse order (id=3 before id=2)
          client = build_async_mock_client(dir, responses: :reverse, reverse_responses: {
                                             2 => refs_a,
                                             3 => refs_b
                                           })

          id_a = client.async_references(file_a, 0, 6)
          id_b = client.async_references(file_b, 0, 6)

          # Collect id_a first — but server responds with id_b first
          result_a = client.collect_response(id_a)
          result_b = client.collect_response(id_b)

          assert_equal refs_a, result_a
          assert_equal refs_b, result_b
        end
      ensure
        FileUtils.remove_entry(dir) if dir
      end

      private

      def build_async_mock_client(project_root, responses: {}, reverse_responses: nil)
        client = Client.allocate
        client.instance_variable_set(:@project_root, File.expand_path(project_root))
        client.instance_variable_set(:@request_id, 0)
        client.instance_variable_set(:@started, false)
        client.instance_variable_set(:@opened_files, Set.new)

        client.send(:check_sorbet_cache)

        stdin_read, stdin_write = IO.pipe
        stdout_read, stdout_write = IO.pipe

        client.instance_variable_set(:@stdin, stdin_write)
        client.instance_variable_set(:@stdout, stdout_read)
        client.instance_variable_set(:@stderr_thread, nil)
        client.instance_variable_set(:@wait_thread, nil)
        client.instance_variable_set(:@started, true)

        Thread.new do
          # Respond to initialize (id=1)
          write_lsp_message(stdout_write, { "jsonrpc" => "2.0", "id" => 1, "result" => { "capabilities" => {} } })

          if responses == :reverse && reverse_responses
            # Send responses in reverse ID order
            reverse_responses.keys.sort.reverse.each do |id|
              write_lsp_message(stdout_write, { "jsonrpc" => "2.0", "id" => id, "result" => reverse_responses[id] })
            end
          else
            responses.keys.sort.each do |id|
              write_lsp_message(stdout_write, { "jsonrpc" => "2.0", "id" => id, "result" => responses[id] })
            end
          end

          write_lsp_message(stdout_write, { "jsonrpc" => "2.0", "id" => 999, "result" => nil })
        rescue IOError, Errno::EPIPE
          # Pipe closed
        end

        client.send(:send_initialize)
        client.send(:send_initialized)

        Thread.new do
          stdin_read.read
        rescue StandardError
          nil
        end

        client
      end

      def write_lsp_message(io, message)
        json = JSON.generate(message)
        io.write("Content-Length: #{json.bytesize}\r\n\r\n")
        io.write(json)
        io.flush
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
