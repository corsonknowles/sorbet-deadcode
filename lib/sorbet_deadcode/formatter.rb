# frozen_string_literal: true

require "json"

module SorbetDeadcode
  # Renders classified dead-code results (Classifier::Result) in a chosen output format
  # (issue #139). Pure string production over already-classified+sorted results, so the CLI
  # stays a thin caller and the rendering is unit-tested in isolation.
  #
  #   text     — the default human-readable tiered list (one indented entry per candidate).
  #   markdown  — candidates grouped by suggested action under `### <action> (n)` headings,
  #               rendered as a table; paste-ready for a PR body.
  #   json      — a machine-readable array of objects for piping into other tooling.
  module Formatter
    FORMATS = %i[text markdown json].freeze

    module_function

    # @param results [Array<Classifier::Result>] already filtered + sorted by the caller
    # @param format [Symbol] one of FORMATS
    # @return [String]
    def render(results, format:)
      case format
      when :markdown then markdown(results)
      when :json then json(results)
      else text(results)
      end
    end

    def text(results)
      results.map { |result| text_entry(result) }.join("\n")
    end

    def text_entry(result)
      defn = result.definition
      entry = "  [#{result.suggested_action}] [#{result.confidence}] #{defn.kind} #{defn.full_name} " \
        "(refs=#{result.external_reference_count}#{flags_suffix(result)})\n    #{defn.location}"
      entry += "\n    added: #{result.added}" if result.added
      entry += "\n    dead_since: #{result.dead_since}" if result.dead_since
      entry
    end

    def flags_suffix(result)
      result.flags.empty? ? "" : " flags=#{result.flags.join(',')}"
    end

    def markdown(results)
      results.group_by(&:suggested_action).map do |action, group|
        rows = group.map { |result| markdown_row(result) }
        "### #{action} (#{group.size})\n\n" \
          "| kind | name | location | refs | flags | added | dead_since |\n" \
          "| --- | --- | --- | --- | --- | --- | --- |\n" +
          rows.join("\n")
      end.join("\n\n")
    end

    def markdown_row(result)
      defn = result.definition
      flags = result.flags.empty? ? "" : "`#{result.flags.join(', ')}`"
      added = result.added ? "`#{result.added}`" : ""
      dead_since = result.dead_since ? "`#{result.dead_since}`" : ""
      "| #{defn.kind} | `#{defn.full_name}` | `#{defn.location}` | #{result.external_reference_count} | " \
        "#{flags} | #{added} | #{dead_since} |"
    end

    def json(results)
      JSON.generate(results.map do |result|
        defn = result.definition
        {
          action: result.suggested_action,
          confidence: result.confidence,
          kind: defn.kind,
          full_name: defn.full_name,
          location: defn.location,
          external_reference_count: result.external_reference_count,
          flags: result.flags,
          added: result.added,
          dead_since: result.dead_since,
        }
      end)
    end
  end
end
