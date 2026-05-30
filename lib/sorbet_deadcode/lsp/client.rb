# frozen_string_literal: true

require "json"
require "open3"

module SorbetDeadcode
  module Lsp
    class Client
      class Error < StandardError; end

      attr_reader :project_root

      def initialize(project_root)
        @project_root = File.expand_path(project_root)
        @request_id = 0
        @started = false

        check_sorbet_cache
        start_server
        send_initialize
        send_initialized
      end

      def references(file_path, line, column)
        uri = "file://#{File.expand_path(file_path)}"
        send_did_open(uri, file_path)

        result = send_request("textDocument/references", {
          "textDocument" => { "uri" => uri },
          "position" => { "line" => line, "character" => column },
          "context" => { "includeDeclaration" => false },
        })

        result || []
      end

      def shutdown
        return unless @started

        send_request("shutdown", nil)
        send_notification("exit", nil)

        @stdin&.close
        @stdout&.close
        @stderr_thread&.join(5)
        @wait_thread&.join(5)

        if @wait_thread&.alive?
          Process.kill("TERM", @wait_thread.pid)
          @wait_thread.join(5)
        end
      rescue Errno::ESRCH, IOError
        # Process already exited
      ensure
        @started = false
      end

      private

      def check_sorbet_cache
        cache_dir = File.join(@project_root, "tmp", "cache", "sorbet")
        return if File.directory?(cache_dir)

        $stderr.puts(
          "Sorbet cache not found at tmp/cache/sorbet. " \
          "Run 'srb tc' first to build the cache. " \
          "LSP startup will be slow without it.",
        )
      end

      def start_server
        @stdin, @stdout, @stderr_thread, @wait_thread = Open3.popen3(
          "bundle", "exec", "srb", "tc", "--lsp", "--disable-watchman",
          chdir: @project_root,
        )
        @started = true
        @opened_files = Set.new
      end

      def send_initialize
        send_request("initialize", {
          "rootUri" => "file://#{@project_root}",
          "capabilities" => {},
        })
      end

      def send_initialized
        send_notification("initialized", {})
      end

      def send_did_open(uri, file_path)
        return if @opened_files.include?(uri)

        text = File.read(File.expand_path(file_path))
        send_notification("textDocument/didOpen", {
          "textDocument" => {
            "uri" => uri,
            "languageId" => "ruby",
            "version" => 1,
            "text" => text,
          },
        })
        @opened_files.add(uri)
      end

      def next_id
        @request_id += 1
      end

      def send_request(method, params)
        id = next_id
        message = {
          "jsonrpc" => "2.0",
          "id" => id,
          "method" => method,
          "params" => params,
        }
        write_message(message)
        read_response(id)
      end

      def send_notification(method, params)
        message = {
          "jsonrpc" => "2.0",
          "method" => method,
          "params" => params,
        }
        write_message(message)
      end

      def write_message(message)
        json = JSON.generate(message)
        header = "Content-Length: #{json.bytesize}\r\n\r\n"
        @stdin.write(header)
        @stdin.write(json)
        @stdin.flush
      end

      def read_response(expected_id)
        loop do
          message = read_message
          return nil unless message

          if message.key?("id") && message["id"] == expected_id
            if message.key?("error")
              raise Error, "LSP error: #{message["error"]["message"]}"
            end
            return message["result"]
          end
          # Skip notifications and responses with other IDs
        end
      end

      def read_message
        content_length = nil

        loop do
          line = @stdout.gets
          return nil if line.nil?

          line = line.strip
          if line.empty?
            break if content_length
            next
          end

          if line.start_with?("Content-Length:")
            content_length = line.split(":").last.strip.to_i
          end
        end

        return nil unless content_length

        body = @stdout.read(content_length)
        return nil if body.nil? || body.empty?

        JSON.parse(body)
      end
    end
  end
end
