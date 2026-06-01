# frozen_string_literal: true

require "json"

module SorbetDeadcode
  # Serialisable snapshot of a full dead-code analysis run.
  # Stores the raw list of dead definitions so the caller can later filter by
  # path, intersect with another tool's output, or generate reports without
  # re-running the (potentially slow) analysis.
  class Index
    VERSION = 1

    attr_reader :dead_definitions, :created_at, :paths, :exclude_paths

    def initialize(dead_definitions:, paths:, exclude_paths: [])
      @dead_definitions = dead_definitions
      @paths = Array(paths)
      @exclude_paths = Array(exclude_paths)
      @created_at = Time.now.iso8601
    end

    # Serialize to a JSON string.
    def to_json(*)
      JSON.generate({
        "version" => VERSION,
        "created_at" => @created_at,
        "paths" => @paths,
        "exclude_paths" => @exclude_paths,
        "dead_definitions" => @dead_definitions.map { |d| serialize_definition(d) },
      })
    end

    # Write to a file path.
    def write(output_path)
      File.write(output_path, to_json)
      output_path
    end

    # Load from a JSON file or string.
    def self.load(source)
      data = source.is_a?(String) && File.exist?(source) ? File.read(source) : source
      parsed = JSON.parse(data)

      defs = (parsed["dead_definitions"] || []).map { |d| deserialize_definition(d) }
      new(
        dead_definitions: defs,
        paths: parsed["paths"] || [],
        exclude_paths: parsed["exclude_paths"] || [],
      ).tap { |idx| idx.instance_variable_set(:@created_at, parsed["created_at"]) }
    end

    # Filter dead definitions to those whose location starts with one of the given paths.
    def filter_paths(paths)
      paths = Array(paths).map { |p| File.expand_path(p) }
      filtered = @dead_definitions.select do |d|
        file = d.file
        abs = File.expand_path(file)
        paths.any? { |p| abs.start_with?(p) }
      end
      self.class.new(dead_definitions: filtered, paths: paths, exclude_paths: @exclude_paths)
    end

    # Return only definitions whose location matches any of the given pack/path prefixes.
    def for_paths(*path_prefixes)
      filter_paths(path_prefixes)
    end

    # Intersect this index with another (e.g. from Spoom).
    # Returns definitions whose name+kind appear in both.
    def intersect(other)
      other_keys = Set.new(other.dead_definitions.map { |d| [d.name, d.kind] })
      shared = @dead_definitions.select { |d| other_keys.include?([d.name, d.kind]) }
      self.class.new(dead_definitions: shared, paths: @paths, exclude_paths: @exclude_paths)
    end

    private

    def serialize_definition(definition)
      {
        "name" => definition.name,
        "full_name" => definition.full_name,
        "kind" => definition.kind.to_s,
        "location" => definition.location,
        "owner_name" => definition.owner_name,
      }
    end

    def self.deserialize_definition(hash)
      Definition.new(
        name: hash["name"],
        full_name: hash["full_name"],
        kind: hash["kind"].to_sym,
        location: hash["location"],
        owner_name: hash["owner_name"],
      )
    end
    private_class_method :deserialize_definition
  end
end
