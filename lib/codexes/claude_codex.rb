# frozen_string_literal: true

require_relative 'base_codex'
require 'json'
require 'open3'
require 'time'
require 'timeout'
require 'shellwords'

# Claude Code CLI adapter
class ClaudeCodex < BaseCodex
  def initialize(config = {})
    super('claude', config)
    @extra_path = config[:extra_path] || ''
  end

  def version
    result = run_cmd('claude --version 2>/dev/null || echo unknown')
    result[:stdout].strip
  end

  def warmup(warmup_dir)
    puts '  Warmup: Running trivial prompt on Claude...'
    result = run_generation('Respond with just the word OK.', dir: warmup_dir)
    puts "  Warmup done in #{result[:elapsed_seconds]}s (success=#{result[:success]})"
    result
  end

  def run_generation(prompt, dir:, log_path: nil)
    env_prefix = "unset CLAUDECODE && export PATH=#{@extra_path}:$PATH && "
    cmd = "#{env_prefix}claude -p #{Shellwords.escape(prompt)} --dangerously-skip-permissions --output-format json"

    start_time = Time.now
    result = run_cmd(cmd, dir: dir, timeout: 1200)
    elapsed = Time.now - start_time

    if log_path
      FileUtils.mkdir_p(File.dirname(log_path))
      File.write(log_path, result[:stdout])
    end

    {
      success: result[:success],
      elapsed_seconds: elapsed.round(1),
      metrics: parse_metrics(result[:stdout]),
      stdout: result[:stdout],
      stderr: result[:stderr]
    }
  end

  def parse_metrics(raw_output)
    raw_output = raw_output.dup.force_encoding('UTF-8')
    events = JSON.parse(raw_output.strip)
    events = [events] unless events.is_a?(Array)
    result_event = events.reverse.find { |e| e.is_a?(Hash) && e['type'] == 'result' }
    return nil unless result_event

    usage = result_event['usage'] || {}
    {
      input_tokens: usage['input_tokens'] || 0,
      output_tokens: usage['output_tokens'] || 0,
      cache_creation_tokens: usage['cache_creation_input_tokens'] || 0,
      cache_read_tokens: usage['cache_read_input_tokens'] || 0,
      cost_usd: result_event['total_cost_usd'] || 0.0,
      num_turns: result_event['num_turns'] || 0,
      duration_ms: result_event['duration_ms'] || 0,
    }
  rescue JSON::ParserError => e
    puts "  WARNING: Failed to parse Claude JSON output: #{e.message}"
    nil
  end

  private

  def run_cmd(cmd, dir: nil, timeout: 600)
    opts = {}
    opts[:chdir] = dir if dir
    stdin_r, stdout_r, stderr_r, wait_thr = Open3.popen3(cmd, **opts)
    stdin_r.close
    stdout_r.set_encoding('UTF-8')
    stderr_r.set_encoding('UTF-8')
    stdout = stderr = ''
    begin
      Timeout.timeout(timeout) do
        stdout = stdout_r.read
        stderr = stderr_r.read
      end
    rescue Timeout::Error
      Process.kill('TERM', wait_thr.pid) rescue nil
      stdout = stdout_r.read rescue ''
      stderr = "Timeout after #{timeout}s"
    end
    stdout_r.close
    stderr_r.close
    status = wait_thr.value
    { stdout: stdout, stderr: stderr, exit_code: status.exitstatus, success: status.success? }
  end
end
