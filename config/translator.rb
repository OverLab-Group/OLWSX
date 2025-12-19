#!/usr/bin/env ruby
# =============================================================================
# OLWSX - OverLab Web ServerX
# File: config/translator.rb
# Role: Final translators from htaccess/nginx.conf to canonical JSON schema
# Philosophy: One version, the most stable version, first and last.
# -----------------------------------------------------------------------------
# This tool ingests simplified subsets of Apache .htaccess and Nginx config
# and outputs OLWSX canonical JSON schema (same format wsx.rb compiler emits).
# It is deterministic, with explicit limitations documented here:
# - Apache: RewriteRule, Header set/add, SetEnvIfNoCase User-Agent, Deny path.
# - Nginx: location prefix, add_header, return <code>, limit_req.
# =============================================================================

require 'json'

module OLWSX
  module Translator
    VERSION = '1.0.0'

    FLAGS = {
      'COMP_NONE' => 0x00000000,
      'CACHE_MISS' => 0x00010000,
      'SEC_OK' => 0x00100000
    }.freeze

    def self.htaccess_to_schema(text, generation: 0)
      routes, waf_rules, headers = [], [], []
      ratelimit = nil

      text.each_line do |line|
        ln = line.strip
        next if ln.empty? || ln.start_with?('#')

        if ln =~ /^RewriteRule\s+\^?\/?([^\s]+)\s+-(\s+\[R=(\d+)\])?/i
          prefix = "/#{$1}".gsub(%r{//+}, '/')
          status = ($3 ? $3.to_i : 200)
          routes << {
            "match_prefix" => prefix,
            "status_override" => status,
            "static_body" => nil,
            "resp_headers" => "",
            "meta_flags" => FLAGS['COMP_NONE'] | FLAGS['CACHE_MISS'] | FLAGS['SEC_OK']
          }
        elsif ln =~ /^Header\s+(set|add)\s+([A-Za-z0-9\-\_]+)\s+"([^"]+)"\s*(.*)$/i
          key, val, path = $2, $3, $4.strip
          prefix = path =~ /env=.+/i ? "/" : (path.empty? ? "/" : path)
          headers << { "prefix" => prefix, "line" => "#{key}: #{val}\r\n" }
        elsif ln =~ /^SetEnvIfNoCase\s+User-Agent\s+"([^"]+)"\s+deny/i
          waf_rules << { "type" => "block_useragent_contains", "value" => $1 }
        elsif ln =~ /^RewriteCond\s+\%\{REQUEST_URI\}\s+\.\.\/\s*\n?RewriteRule/i
          waf_rules << { "type" => "block_path_contains", "value" => "../" }
        elsif ln =~ /^#\s*limit_req\s+(\d+)\/s/i
          cap = $1.to_i
          ratelimit = { "capacity" => cap, "refill_per_s" => cap/2, "retry_after_s" => 1 }
        end
      end

      # Merge headers by prefix
      hdr_map = Hash.new { |h,k| h[k] = [] }
      headers.each { |h| hdr_map[h["prefix"]] << h["line"] }

      routes.each do |r|
        r["resp_headers"] = hdr_map[r["match_prefix"]].join
      end

      {
        "version" => VERSION,
        "generation" => generation,
        "routes" => routes,
        "security" => { "waf_rules" => waf_rules, "ratelimit" => ratelimit },
        "cache" => { "warmup_l2" => [] }
      }
    end

    def self.nginx_to_schema(text, generation: 0)
      routes, waf_rules = [], []
      headers_by_loc = Hash.new { |h,k| h[k] = [] }
      ratelimit = nil
      current_loc = nil

      text.each_line do |line|
        ln = line.strip
        next if ln.empty? || ln.start_with?('#')

        if ln =~ /^location\s+\/([^\s\{]+)\s*\{/i
          current_loc = "/#{$1}"
        elsif ln =~ /^\}/
          current_loc = nil
        elsif ln =~ /^add_header\s+([A-Za-z0-9\-\_]+)\s+(.+);/i
          key, val = $1, $2.gsub(/[";]/, '').strip
          prefix = current_loc || "/"
          headers_by_loc[prefix] << "#{key}: #{val}\r\n"
        elsif ln =~ /^return\s+(\d+);/i
          code = $1.to_i
          prefix = current_loc || "/"
          routes << {
            "match_prefix" => prefix,
            "status_override" => code,
            "static_body" => nil,
            "resp_headers" => "",
            "meta_flags" => FLAGS['COMP_NONE'] | FLAGS['CACHE_MISS'] | FLAGS['SEC_OK']
          }
        elsif ln =~ /^limit_req_zone/
          # simplistic mapping to ratelimit
          ratelimit ||= { "capacity" => 60, "refill_per_s" => 30, "retry_after_s" => 1 }
        elsif ln =~ /(\.\.\/)/
          waf_rules << { "type" => "block_path_contains", "value" => "../" }
        elsif ln =~ /sqlmap/i
          waf_rules << { "type" => "block_useragent_contains", "value" => "sqlmap" }
        end
      end

      routes.each do |r|
        r["resp_headers"] = headers_by_loc[r["match_prefix"]].join
      end

      {
        "version" => VERSION,
        "generation" => generation,
        "routes" => routes,
        "security" => { "waf_rules" => waf_rules, "ratelimit" => ratelimit },
        "cache" => { "warmup_l2" => [] }
      }
    end

    class CLI
      def self.run(argv)
        cmd = argv.shift
        case cmd
        when 'htaccess'
          file = argv.shift or return usage("Missing <file.htaccess>")
          gen = argv.include?('--generation') ? Integer(argv[argv.index('--generation')+1]) : 0
          text = File.read(file)
          puts JSON.pretty_generate(Translator.htaccess_to_schema(text, generation: gen))
        when 'nginx'
          file = argv.shift or return usage("Missing <nginx.conf>")
          gen = argv.include?('--generation') ? Integer(argv[argv.index('--generation')+1]) : 0
          text = File.read(file)
          puts JSON.pretty_generate(Translator.nginx_to_schema(text, generation: gen))
        else
          usage(nil)
        end
      rescue => e
        $stderr.puts e.message
        exit 1
      end

      def self.usage(msg)
        $stderr.puts msg if msg
        puts <<~U
          Translator (final & frozen)

          Usage:
            translator.rb htaccess <file.htaccess> [--generation N]
            translator.rb nginx <nginx.conf> [--generation N]
        U
        exit(msg ? 1 : 0)
      end
    end
  end
end

if __FILE__ == $0
  OLWSX::Translator::CLI.run(ARGV.dup)
end