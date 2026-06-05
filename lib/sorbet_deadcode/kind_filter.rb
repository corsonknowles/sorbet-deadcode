# frozen_string_literal: true


module SorbetDeadcode
  # Parses the `--kind` CLI value into the set of definition kinds to report. Methods are the
  # default (the highest-value, lowest-risk target and the one the type-aware engine is built for);
  # pass `all` or an explicit list to include constants/classes/modules/accessors. Pure + unit-tested
  # so the CLI stays a thin caller.
  module KindFilter
    module_function

    # Every kind a Definition can carry (see Collector::DefinitionCollector).
    ALL = %i[method constant class module attr_reader attr_writer].freeze

    # Accepted tokens → canonical kind. Singular and `s`-plural forms both map; `all` is handled
    # separately. attr_reader/attr_writer also accept their plural and the `accessor` umbrella.
    ALIASES = {
      "method" => :method, "methods" => :method,
      "constant" => :constant, "constants" => :constant,
      "class" => :class, "classes" => :class,
      "module" => :module, "modules" => :module,
      "attr_reader" => :attr_reader, "attr_readers" => :attr_reader,
      "attr_writer" => :attr_writer, "attr_writers" => :attr_writer,
    }.freeze

    DEFAULT = "method"

    Result = Struct.new(:kinds, :invalid, keyword_init: true)

    # @param value [String] the raw --kind value (comma-separated)
    # @return [Result] kinds: Set<Symbol> of canonical kinds; invalid: Array<String> unknown tokens
    def parse(value)
      tokens = value.to_s.split(",").map { |token| token.strip.downcase }.reject(&:empty?)
      return Result.new(kinds: ALL.to_set, invalid: []) if tokens.include?("all")

      invalid = tokens.reject { |token| ALIASES.key?(token) }
      Result.new(kinds: tokens.filter_map { |token| ALIASES[token] }.to_set, invalid: invalid)
    end
  end
end
