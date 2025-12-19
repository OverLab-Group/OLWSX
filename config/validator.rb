#!/usr/bin/env ruby
# =============================================================================
# OLWSX - OverLab Web ServerX
# File: config/validator.rb
# Role: Final canonical schema validator
# Philosophy: One version, the most stable version, first and last.
# -----------------------------------------------------------------------------
# Validates JSON objects produced by wsx.rb compiler or translator.rb
# against the frozen canonical schema and limits.
# =============================================================================

require 'json'

module OLWSX
  module CanonicalValidator
    VERSION = '1.0.0'

    LIMITS = {
      max_route_bytes: 65536,
      max_header_bytes: 2 * 1024 * 1024,
      max_body_bytes: 64 * 1024 * 1024,
      max_key_bytes: 65536
    }.freeze

    def self.validate_json!(obj)
      # top-level
      expect_type(obj, Hash, "root")
      expect_value(obj["version"], String, "version")
      expect_value(obj["generation"], Integer, "generation")
      expect_type(obj["routes"], Array, "routes")
      expect_type(obj["security"], Hash, "security")
      expect_type(obj["cache"], Hash, "cache")

      # routes
      obj["routes"].each_with_index do |r, i|
        path = r["match_prefix"]
        expect_value(path, String, "routes[#{i}].match_prefix")
        raise "Route too long at #{i}" if path.bytesize > LIMITS[:max_route_bytes]

        so = r["status_override"]
        raise "status_override must be Integer or nil" unless so.is_a?(Integer) || so.nil?

        sb = r["static_body"]
        raise "static_body must be String or nil" unless sb.is_a?(String) || sb.nil?
        if sb.is_a?(String) && sb.bytesize > LIMITS[:max_body_bytes]
          raise "static_body too large at #{i}"
        end

        rh = r["resp_headers"]
        expect_value(rh, String, "routes[#{i}].resp_headers")
        raise "resp_headers too large at #{i}" if rh.bytesize > LIMITS[:max_header_bytes]

        mf = r["meta_flags"]
        expect_value(mf, Integer, "routes[#{i}].meta_flags")
      end

      # security
      sec = obj["security"]
      expect_type(sec["waf_rules"], Array, "security.waf_rules")
      sec["waf_rules"].each_with_index do |w, i|
        expect_type(w, Hash, "security.waf_rules[#{i}]")
        expect_value(w["type"], String, "waf_rules[#{i}].type")
        expect_value(w["value"], String, "waf_rules[#{i}].value")
        raise "waf_rule value too long at #{i}" if w["value"].bytesize > LIMITS[:max_route_bytes]
      end
      rl = sec["ratelimit"]
      if !rl.nil?
        expect_type(rl, Hash, "security.ratelimit")
        expect_value(rl["capacity"], Integer, "ratelimit.capacity")
        expect_value(rl["refill_per_s"], Integer, "ratelimit.refill_per_s")
        expect_value(rl["retry_after_s"], Integer, "ratelimit.retry_after_s")
        raise "ratelimit.capacity must be > 0" unless rl["capacity"] > 0
        raise "ratelimit.refill_per_s must be > 0" unless rl["refill_per_s"] > 0
        raise "ratelimit.retry_after_s must be >= 0" unless rl["retry_after_s"] >= 0
      end

      # cache
      cache = obj["cache"]
      expect_type(cache["warmup_l2"], Array, "cache.warmup_l2")
      cache["warmup_l2"].each_with_index do |c, i|
        expect_type(c, Hash, "cache.warmup_l2[#{i}]")
        expect_value(c["key"], String, "warmup_l2[#{i}].key")
        expect_value(c["value"], String, "warmup_l2[#{i}].value")
        expect_value(c["flags"], Integer, "warmup_l2[#{i}].flags")
        raise "cache key too long at #{i}" if c["key"].bytesize > LIMITS[:max_key_bytes]
      end

      true
    end

    def self.expect_type(val, klass, path)
      raise "Invalid #{path}: expected #{klass}, got #{val.class}" unless val.is_a?(klass)
    end
    def self.expect_value(val, klass, path)
      raise "Invalid #{path}: expected #{klass}, got #{val.class}" unless val.is_a?(klass)
    end

    class CLI
      def self.run(argv)
        file = argv.shift or return usage("Missing <file.json>")
        obj = JSON.parse(File.read(file))
        validate_json!(obj)
        puts "OK"
      rescue => e
        $stderr.puts e.message
        exit 1
      end

      def self.usage(msg)
        $stderr.puts msg if msg
        puts <<~U
          Canonical Validator (final & frozen)

          Usage:
            validator.rb <file.json>
        U
        exit(msg ? 1 : 0)
      end
    end
  end
end

if __FILE__ == $0
  OLWSX::CanonicalValidator::CLI.run(ARGV.dup)
end