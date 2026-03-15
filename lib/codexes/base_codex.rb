# frozen_string_literal: true

# Base class for AI codex adapters
# Each codex implementation must implement the abstract methods defined here
class BaseCodex
  class CodexError < StandardError; end

  attr_reader :name

  def initialize(name, config = {})
    @name = name
    @config = config
  end

  # Abstract: Run code generation with the given prompt
  # @param prompt [String] The prompt to send to the codex
  # @param dir [String] Working directory for generation
  # @param log_path [String, nil] Optional path to save logs
  # @return [Hash] Result hash with keys:
  #   - :success [Boolean] Whether generation succeeded
  #   - :elapsed_seconds [Float] Time taken
  #   - :metrics [Hash, nil] Token usage, cost, etc.
  def run_generation(prompt, dir:, log_path: nil)
    raise NotImplementedError, "#{self.class} must implement #run_generation"
  end

  # Abstract: Get the version string of this codex
  # @return [String] Version information
  def version
    raise NotImplementedError, "#{self.class} must implement #version"
  end

  # Optional: Perform warmup to initialize caches
  # @param warmup_dir [String] Directory for warmup
  # @return [Hash] Warmup result
  def warmup(warmup_dir)
    # Default no-op implementation
    { success: true, elapsed_seconds: 0.0 }
  end

  # Optional: Parse raw output to extract metrics
  # @param raw_output [String] Raw codex output
  # @return [Hash, nil] Parsed metrics or nil if parsing fails
  def parse_metrics(raw_output)
    nil
  end

  protected

  attr_reader :config
end
