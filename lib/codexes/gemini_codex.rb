# frozen_string_literal: true

require_relative 'base_codex'
require 'net/http'
require 'json'
require 'uri'
require 'time'
require 'fileutils'

# Google Gemini API adapter
class GeminiCodex < BaseCodex
  API_ENDPOINT = 'https://generativelanguage.googleapis.com/v1beta/models'

  # Gemini 3.1 Flash-Lite Official Pricing (Per 1 Million Tokens)
  PRICE_INPUT_1M = 0.25
  PRICE_OUTPUT_1M = 1.5

  def initialize(config = {})
    super('gemini', config)
    @api_key = config[:api_key] || ENV['GOOGLE_API_KEY']
    @model_name = config[:model_name] || 'gemini-3.1-flash-lite-preview'
    @cooldown_seconds = config[:cooldown_seconds] || 1.2

    raise CodexError, 'GOOGLE_API_KEY not configured' unless @api_key
  end

  def version
    @model_name
  end

  def warmup(warmup_dir)
    puts "  Warmup: Running trivial prompt on Gemini (#{@model_name})..."
    result = run_generation('Respond with just the word OK.', dir: warmup_dir)
    puts "  Warmup done in #{result[:elapsed_seconds]}s (success=#{result[:success]})"
    sleep(@cooldown_seconds)
    result
  end

  def run_generation(prompt, dir:, log_path: nil)
    start_time = Time.now

    begin
      response_text, input_tokens, output_tokens = call_gemini_api(prompt)

      # Calculate cost
      cost_usd = calculate_cost(input_tokens, output_tokens)

      elapsed = Time.now - start_time

      # Save to log if requested
      if log_path
        FileUtils.mkdir_p(File.dirname(log_path))
        log_data = {
          model: @model_name,
          prompt: prompt,
          response: response_text,
          input_tokens: input_tokens,
          output_tokens: output_tokens,
          cost_usd: cost_usd,
          elapsed_seconds: elapsed.round(1)
        }
        File.write(log_path, JSON.pretty_generate(log_data))
      end

      # Save generated code to working directory
      save_generated_code(response_text, dir)

      # Cooldown to respect rate limits
      sleep(@cooldown_seconds)

      {
        success: true,
        elapsed_seconds: elapsed.round(1),
        metrics: {
          input_tokens: input_tokens,
          output_tokens: output_tokens,
          cost_usd: cost_usd,
          model: @model_name
        },
        response_text: response_text
      }
    rescue StandardError => e
      elapsed = Time.now - start_time
      {
        success: false,
        elapsed_seconds: elapsed.round(1),
        metrics: nil,
        error: e.message
      }
    end
  end

  private

  def call_gemini_api(prompt)
    uri = URI("#{API_ENDPOINT}/#{@model_name}:generateContent?key=#{@api_key}")

    request_body = {
      contents: [{
        parts: [{ text: prompt }]
      }]
    }

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.read_timeout = 600

    request = Net::HTTP::Post.new(uri)
    request['Content-Type'] = 'application/json'
    request.body = JSON.generate(request_body)

    response = http.request(request)

    unless response.is_a?(Net::HTTPSuccess)
      raise CodexError, "Gemini API error: #{response.code} #{response.message}\n#{response.body}"
    end

    data = JSON.parse(response.body)

    # Extract response text
    response_text = data.dig('candidates', 0, 'content', 'parts', 0, 'text') || ''

    # Extract token counts
    usage = data['usageMetadata'] || {}
    input_tokens = usage['promptTokenCount'] || 0
    output_tokens = usage['candidatesTokenCount'] || 0

    [response_text, input_tokens, output_tokens]
  end

  def calculate_cost(input_tokens, output_tokens)
    input_cost = (input_tokens / 1_000_000.0) * PRICE_INPUT_1M
    output_cost = (output_tokens / 1_000_000.0) * PRICE_OUTPUT_1M
    (input_cost + output_cost).round(8)
  end

  def save_generated_code(response_text, dir)
    # Extract code from markdown code blocks if present
    code_blocks = response_text.scan(/```(?:\w+)?\n(.*?)```/m)

    if code_blocks.empty?
      # No code blocks found, save entire response as code
      code = response_text.strip
    else
      # Use the largest code block (likely the main implementation)
      code = code_blocks.max_by { |block| block[0].length }[0]
    end

    # Detect if this is a script (shebang) or needs to be saved with extension
    if code.start_with?('#!')
      # Save as executable script
      File.write(File.join(dir, 'minigit'), code)
      FileUtils.chmod(0755, File.join(dir, 'minigit'))
    else
      # For now, just write the code - the test script will handle compilation
      # In a full implementation, we'd detect the language and save appropriately
      File.write(File.join(dir, 'generated_code.txt'), code)
    end
  end
end
