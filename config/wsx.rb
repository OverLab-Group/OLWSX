#!/usr/bin/env ruby
# =============================================================================
# OLWSX - OverLab Web ServerX
# File: config/wsx.rb
# Role: Final & Stable Config DSL (parser, validator, compiler)
# Philosophy: One version, the most stable version, first and last.
# -----------------------------------------------------------------------------
# This is the definitive, complete, and frozen WSX DSL implementation.
# No features will ever be added or removed.
#
# Scope:
# - Textual DSL for OLWSX configuration (*.wsx).
# - Deterministic tokenizer and parser with explicit errors.
# - Structural validator (limits aligned with Core).
# - Canonical compiler to a JSON schema (stable forever).
# - CLI interface: lint, compile, print-schema, example, help.
# =============================================================================

require 'json'

module WSX
  VERSION = '1.0.0'

  LIMITS = {
    max_route_bytes: 65536,
    max_header_bytes: 2 * 1024 * 1024,
    max_body_bytes: 64 * 1024 * 1024,
    max_key_bytes: 65536
  }.freeze

  FLAGS = {
    'COMP_NONE' => 0x00000000,
    'COMP_GZIP' => 0x00000001,
    'COMP_ZSTD' => 0x00000002,
    'COMP_BROTLI' => 0x00000004,
    'CACHE_MISS' => 0x00010000,
    'CACHE_L1' => 0x00020000,
    'CACHE_L2' => 0x00040000,
    'CACHE_L3' => 0x00080000,
    'SEC_OK' => 0x00100000,
    'SEC_WAF' => 0x00200000,
    'SEC_RATELIM' => 0x00400000
  }.freeze

  class Token
    attr_reader :type, :value, :line, :col
    def initialize(type, value, line, col)
      @type, @value, @line, @col = type, value, line, col
    end
  end

  class Lexer
    def initialize(text)
      @t = text; @i = 0; @line = 1; @col = 1
    end
    def tokenize
      toks = []
      while @i < @t.length
        ch = @t[@i]
        case ch
        when ' ', "\t", "\r" then adv(1)
        when "\n" then toks << Token.new(:NL, "\n", @line, @col); adv(1); @line += 1; @col = 1
        when '#'
          adv(1)
          adv(1) while @i < @t.length && @t[@i] != "\n"
        when '"'
          toks << string
        when ':', ',', '<', '>'
          toks << Token.new(ch.to_sym, ch, @line, @col); adv(1)
        else
          if ch =~ /[A-Za-z_]/
            toks << ident
          elsif ch =~ /[0-9]/
            toks << integer
          else
            raise lex_err("Unexpected character #{ch.inspect}")
          end
        end
      end
      toks
    end

    private
    def adv(n) ; @i += n; @col += n; end
    def string
      sl, sc = @line, @col
      adv(1)
      buf = +''
      while @i < @t.length
        ch = @t[@i]
        case ch
        when '"'
          adv(1); return Token.new(:STRING, buf, sl, sc)
        when '\\'
          adv(1); raise lex_err('Unfinished escape') if @i >= @t.length
          esc = @t[@i]
          buf << case esc
                 when 'n' then "\n"; when 'r' then "\r"; when 't' then "\t"
                 when '"' then '"';  when '\\' then '\\'
                 else raise lex_err("Unsupported escape \\#{esc}")
                 end
          adv(1)
        else
          buf << ch; adv(1)
        end
      end
      raise lex_err('Unterminated string literal')
    end
    def ident
      sl, sc = @line, @col
      buf = +''
      while @i < @t.length && @t[@i] =~ /[A-Za-z0-9_\/\.\-]/
        buf << @t[@i]; adv(1)
      end
      Token.new(:IDENT, buf, sl, sc)
    end
    def integer
      sl, sc = @line, @col; buf = +''
      while @i < @t.length && @t[@i] =~ /[0-9]/; buf << @t[@i]; adv(1); end
      Token.new(:INT, buf.to_i, sl, sc)
    end
    def lex_err(msg) ; RuntimeError.new("Lexer error at line #{@line}, col #{@col}: #{msg}"); end
  end

  RouteNode     = Struct.new(:prefix, :status_override, :static_body, :flags)
  HeaderNode    = Struct.new(:key, :value, :prefix)
  WafRuleNode   = Struct.new(:type, :value)
  RateLimitNode = Struct.new(:capacity, :refill_per_s, :retry_after_s)
  CacheWarmupNode = Struct.new(:key, :value, :flags)
  GenerationNode  = Struct.new(:generation)

  class Parser
    def initialize(tokens) ; @tokens = tokens; @pos = 0; end
    def parse
      routes, headers, waf_rules = [], [], []
      ratelimit, cache_warmups, generation = nil, [], nil
      while !eof?
        tok = peek
        if tok.type == :NL then consume; next end
        if tok.type == :IDENT
          case tok.value
          when 'route'      then routes << parse_route
          when 'header'     then headers << parse_header
          when 'waf'        then waf_rules << parse_waf_rule
          when 'ratelimit'  then ratelimit = parse_ratelimit
          when 'cache'      then cache_warmups << parse_cache_warmup
          when 'generation' then generation = parse_generation
          else raise perr("Unknown statement '#{tok.value}'", tok)
          end
          opt_nl
        else
          raise perr("Unexpected token #{tok.type}", tok)
        end
      end
      { routes: routes, headers: headers, waf_rules: waf_rules,
        ratelimit: ratelimit, cache_warmups: cache_warmups, generation: generation }
    end

    private
    def peek ; @tokens[@pos] || Token.new(:EOF, nil, -1, -1) ; end
    def consume ; t = peek; @pos += 1; t ; end
    def expect(type, value=nil)
      t = consume
      if t.type != type || (!value.nil? && t.value != value)
        raise perr("Expected #{type}#{value ? " #{value}" : ''}, got #{t.type} #{t.value.inspect}", t)
      end
      t
    end
    def opt_nl ; consume while peek.type == :NL ; end
    def parse_route
      expect(:IDENT, 'route')
      prefix = expect(:STRING).value
      status_override, static_body, flags = nil, nil, []
      while peek.type == :IDENT
        case peek.value
        when 'status' then consume; status_override = expect(:INT).value
        when 'body'   then consume; static_body     = expect(:STRING).value
        when 'flags'  then consume; flags           = parse_flags
        else break
        end
      end
      RouteNode.new(prefix, status_override, static_body, flags)
    end
    def parse_flags
      list = []
      loop do
        t = expect(:IDENT); list << t.value
        break unless peek.type == :','; consume
      end
      list
    end
    def parse_header
      expect(:IDENT, 'header')
      key = expect(:STRING).value
      expect(:':', ':')
      val = expect(:STRING).value
      expect(:IDENT, 'for')
      prefix = expect(:STRING).value
      HeaderNode.new(key, val, prefix)
    end
    def parse_waf_rule
      expect(:IDENT, 'waf')
      t = expect(:IDENT)
      case t.value
      when 'block_path_contains'     then WafRuleNode.new('block_path_contains', expect(:STRING).value)
      when 'block_useragent_contains' then WafRuleNode.new('block_useragent_contains', expect(:STRING).value)
      else raise perr("Unknown WAF rule '#{t.value}'", t)
      end
    end
    def parse_ratelimit
      expect(:IDENT, 'ratelimit'); expect(:IDENT, 'capacity')
      capacity = expect(:INT).value
      expect(:IDENT, 'refill_per_s'); refill = expect(:INT).value
      expect(:IDENT, 'retry_after_s'); retry_after = expect(:INT).value
      RateLimitNode.new(capacity, refill, retry_after)
    end
    def parse_cache_warmup
      expect(:IDENT, 'cache'); expect(:IDENT, 'warmup_l2')
      expect(:IDENT, 'key'); key = expect(:STRING).value
      expect(:IDENT, 'value'); val = expect(:STRING).value
      flags = []
      if peek.type == :IDENT && peek.value == 'flags'
        consume; flags = parse_flags
      end
      CacheWarmupNode.new(key, val, flags)
    end
    def parse_generation
      expect(:IDENT, 'generation'); GenerationNode.new(expect(:INT).value)
    end
    def perr(msg, tok) ; RuntimeError.new("Parser error at line #{tok.line}, col #{tok.col}: #{msg}") ; end
    def eof? ; peek.type == :EOF ; end
  end

  class Validator
    def self.validate!(ast)
      ast[:routes].each do |r|
        raise "Route prefix too long" if r.prefix.bytesize > LIMITS[:max_route_bytes]
        if r.static_body && r.static_body.bytesize > LIMITS[:max_body_bytes]
          raise "Static body too large"
        end
        r.flags.each { |f| raise "Unknown flag #{f}" unless FLAGS.key?(f) }
      end
      grouped = Hash.new { |h,k| h[k] = [] }
      ast[:headers].each do |h|
        raise "Header key empty" if h.key.empty?
        raise "Header value empty" if h.value.empty?
        grouped[h.prefix] << "#{h.key}: #{h.value}\r\n"
      end
      grouped.each do |prefix, lines|
        total = lines.join
        raise "Headers too large for prefix #{prefix}" if total.bytesize > LIMITS[:max_header_bytes]
      end
      ast[:waf_rules].each { |w| raise "WAF value too long" if w.value.bytesize > LIMITS[:max_route_bytes] }
      if rl = ast[:ratelimit]
        raise "Invalid ratelimit capacity" unless rl.capacity.is_a?(Integer) && rl.capacity > 0
        raise "Invalid ratelimit refill_per_s" unless rl.refill_per_s.is_a?(Integer) && rl.refill_per_s > 0
        raise "Invalid ratelimit retry_after_s" unless rl.retry_after_s.is_a?(Integer) && rl.retry_after_s >= 0
      end
      ast[:cache_warmups].each do |c|
        raise "Cache key too long" if c.key.bytesize > LIMITS[:max_key_bytes]
        c.flags.each { |f| raise "Unknown flag #{f}" unless FLAGS.key?(f) }
      end
      if gen = ast[:generation]
        raise "Invalid generation" unless gen.generation.is_a?(Integer) && gen.generation >= 0
      end
      true
    end
  end

  class Compiler
    def self.compile(ast, override_generation: nil)
      headers_by_prefix = Hash.new { |h,k| h[k] = [] }
      ast[:headers].each { |h| headers_by_prefix[h.prefix] << "#{h.key}: #{h.value}\r\n" }
      routes = ast[:routes].map do |r|
        {
          "match_prefix" => r.prefix,
          "status_override" => r.status_override,
          "static_body" => r.static_body,
          "resp_headers" => headers_by_prefix[r.prefix].join,
          "meta_flags" => fold_flags(r.flags)
        }
      end
      security = {
        "waf_rules" => ast[:waf_rules].map { |w| { "type" => w.type, "value" => w.value } },
        "ratelimit" => (ast[:ratelimit] ? {
          "capacity" => ast[:ratelimit].capacity,
          "refill_per_s" => ast[:ratelimit].refill_per_s,
          "retry_after_s" => ast[:ratelimit].retry_after_s
        } : nil)
      }
      cache = {
        "warmup_l2" => ast[:cache_warmups].map { |c|
          { "key" => c.key, "value" => c.value, "flags" => fold_flags(c.flags) }
        }
      }
      generation = override_generation || (ast[:generation]&.generation) || 0
      {
        "version" => VERSION,
        "generation" => generation,
        "routes" => routes,
        "security" => security,
        "cache" => cache
      }
    end
    def self.fold_flags(list) ; list.reduce(0) { |acc, name| acc | FLAGS[name] } ; end
  end

  class CLI
    def self.run(argv)
      cmd = argv.shift
      case cmd
      when 'lint'
        file = argv.shift or return usage("Missing <file.wsx>")
        text = File.read(file)
        ast = parse_text(text)
        Validator.validate!(ast)
        puts "OK"
      when 'compile'
        file = argv.shift or return usage("Missing <file.wsx>")
        gen = nil; pretty = false
        while !argv.empty?
          flag = argv.shift
          case flag
          when '--generation' then gen = Integer(argv.shift)
          when '--pretty'     then pretty = true
          else return usage("Unknown flag #{flag}")
          end
        end
        text = File.read(file)
        ast = parse_text(text)
        Validator.validate!(ast)
        json = Compiler.compile(ast, override_generation: gen)
        puts(pretty ? JSON.pretty_generate(json) : JSON.generate(json))
      when 'print-schema'
        puts JSON.pretty_generate(example_schema)
      when 'example'
        puts EXAMPLE_WSX
      else
        usage(nil)
      end
    rescue => e
      $stderr.puts e.message
      exit 1
    end

    def self.parse_text(text)
      Parser.new(Lexer.new(text).tokenize).parse
    end

    def self.usage(msg)
      $stderr.puts msg if msg
      puts <<~USAGE
        WSX DSL (final & frozen)

        Usage:
          wsx.rb lint <file.wsx>
          wsx.rb compile <file.wsx> [--generation <uint32>] [--pretty]
          wsx.rb print-schema
          wsx.rb example
          wsx.rb help
      USAGE
      exit(msg ? 1 : 0)
    end

    def self.example_schema
      {
        "version" => VERSION,
        "generation" => 0,
        "routes" => [{
          "match_prefix" => "/example",
          "status_override" => 200,
          "static_body" => "Hello",
          "resp_headers" => "Content-Type: text/plain\r\n",
          "meta_flags" => 0
        }],
        "security" => {
          "waf_rules" => [
            { "type" => "block_path_contains", "value" => "../" },
            { "type" => "block_useragent_contains", "value" => "sqlmap" }
          ],
          "ratelimit" => { "capacity" => 60, "refill_per_s" => 30, "retry_after_s" => 1 }
        },
        "cache" => {
          "warmup_l2" => [ { "key" => "/hello", "value" => "Hello from cache", "flags" => 0 } ]
        }
      }
    end
  end

  EXAMPLE_WSX = <<~WSX
    # Final WSX example (covers routes, headers, security, cache, generation)

    generation 1234

    # Routes
    route "/__status" status 200 body "OK" flags SEC_OK,CACHE_MISS,COMP_NONE
    header "Content-Type" : "text/plain" for "/__status"

    route "/hello" flags SEC_OK,CACHE_MISS,COMP_NONE
    header "Content-Type" : "text/plain" for "/hello"
    header "X-Server" : "OLWSX" for "/hello"

    route "/static/" flags SEC_OK,CACHE_MISS,COMP_NONE

    # Security
    waf block_path_contains "../"
    waf block_useragent_contains "sqlmap"
    ratelimit capacity 60 refill_per_s 30 retry_after_s 1

    # Cache warmup
    cache warmup_l2 key "/hello" value "Hello from OLWSX Core (L2 cached)" flags COMP_NONE,CACHE_L2,SEC_OK
  WSX
end

if __FILE__ == $0
  WSX::CLI.run(ARGV.dup)
end