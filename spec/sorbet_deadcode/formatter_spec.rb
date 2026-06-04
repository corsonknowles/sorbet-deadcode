# frozen_string_literal: true

require_relative "../spec_helper"
require "json"

module SorbetDeadcode
  class FormatterSpec < Minitest::Test
    def result(name:, action:, flags: [], kind: :method, owner: "Foo", refs: 0, confidence: :high, added: nil)
      definition = Definition.new(
        name: name, full_name: "#{owner}##{name}", kind: kind,
        location: "app/models/foo.rb:1", owner_name: owner,
      )
      Classifier::Result.new(
        definition: definition,
        confidence: confidence,
        reference_count: refs,
        external_reference_count: refs,
        flags: flags,
        suggested_action: action,
        added: added,
      )
    end

    def test_text_format_renders_indented_entry_without_flags
      out = Formatter.render([result(name: "bar", action: :safe_delete)], format: :text)

      assert_includes out, "[safe_delete] [high] method Foo#bar (refs=0)"
      assert_includes out, "    app/models/foo.rb:1"
      refute_includes out, "flags="
    end

    def test_text_format_includes_flags_when_present
      out = Formatter.render([result(name: "bar", action: :review, flags: %i[public_api recently_added])], format: :text)

      assert_includes out, "flags=public_api,recently_added"
    end

    def test_text_format_includes_added_history_when_present
      out = Formatter.render(
        [result(name: "bar", action: :safe_delete, added: "abc1234 2024-01-02 Add bar")],
        format: :text,
      )

      assert_includes out, "    added: abc1234 2024-01-02 Add bar"
    end

    def test_text_format_omits_added_line_when_absent
      out = Formatter.render([result(name: "bar", action: :safe_delete)], format: :text)

      refute_includes out, "added:"
    end

    def test_unknown_format_falls_back_to_text
      out = Formatter.render([result(name: "bar", action: :safe_delete)], format: :bogus)

      assert_includes out, "[safe_delete]"
    end

    def test_markdown_groups_by_action_with_tables
      out = Formatter.render(
        [
          result(name: "dead", action: :safe_delete),
          result(name: "iffy", action: :review, flags: [:public_api]),
        ],
        format: :markdown,
      )

      assert_includes out, "### safe_delete (1)"
      assert_includes out, "### review (1)"
      assert_includes out, "| kind | name | location | refs | flags | added |"
      assert_includes out, "| method | `Foo#dead` | `app/models/foo.rb:1` | 0 |  |  |"
      assert_includes out, "`public_api`"
    end

    def test_markdown_includes_added_history_cell_when_present
      out = Formatter.render(
        [result(name: "dead", action: :safe_delete, added: "abc1234 2024-01-02 Add dead")],
        format: :markdown,
      )

      assert_includes out, "`abc1234 2024-01-02 Add dead`"
    end

    def test_json_format_is_parseable_and_complete
      out = Formatter.render(
        [result(name: "bar", action: :safe_delete, flags: [:public_api], refs: 2, confidence: :low)],
        format: :json,
      )
      parsed = JSON.parse(out)

      assert_equal 1, parsed.size
      entry = parsed.first
      assert_equal "safe_delete", entry["action"]
      assert_equal "low", entry["confidence"]
      assert_equal "method", entry["kind"]
      assert_equal "Foo#bar", entry["full_name"]
      assert_equal "app/models/foo.rb:1", entry["location"]
      assert_equal 2, entry["external_reference_count"]
      assert_equal ["public_api"], entry["flags"]
      assert_nil entry["added"]
    end

    def test_json_includes_added_history_when_present
      out = Formatter.render(
        [result(name: "bar", action: :safe_delete, added: "abc1234 2024-01-02 Add bar")],
        format: :json,
      )

      assert_equal "abc1234 2024-01-02 Add bar", JSON.parse(out).first["added"]
    end
  end
end
