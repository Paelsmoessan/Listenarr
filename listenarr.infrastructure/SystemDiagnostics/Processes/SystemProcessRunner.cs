/*
 * Listenarr - Audiobook Management System
 * Copyright (C) 2024-2026 Listenarr Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Affero General Public License as published
 * by the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU Affero General Public License for more details.
 *
 * You should have received a copy of the GNU Affero General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */
using System.Collections.Concurrent;
using System.Diagnostics;
using Microsoft.Extensions.Logging;

namespace Listenarr.Infrastructure.SystemDiagnostics.Processes
{
    public class SystemProcessRunner : IProcessRunner
    {
        private readonly ILogger<SystemProcessRunner> _logger;
        private readonly ConcurrentDictionary<string, int> _transientSensitiveCounts = new(StringComparer.Ordinal);

        public SystemProcessRunner(ILogger<SystemProcessRunner> logger)
        {
            _logger = logger;
        }

        public async Task<ProcessResult> RunAsync(ProcessStartInfo startInfo, int timeoutMs = 60000, CancellationToken cancellationToken = default)
        {
            using var process = new Process();
            process.StartInfo = startInfo;
            process.StartInfo.RedirectStandardOutput = true;
            process.StartInfo.RedirectStandardError = true;
            process.StartInfo.UseShellExecute = false;

            var stdout = string.Empty;
            var stderr = string.Empty;

            try
            {
                process.Start();

                // #737 Bug B: drain both streams to completion with ReadToEndAsync rather than the older
                // BeginOutputReadLine + WaitForExit(timeout) pattern, which truncated large output (big
                // ffprobe JSON on long audiobooks) and yielded empty/partial stdout -> "Failed to parse
                // ffprobe JSON" even though ffprobe exited 0. The reads complete once the pipes close
                // (on normal exit or after Kill), so no output is lost.
                var stdoutTask = process.StandardOutput.ReadToEndAsync();
                var stderrTask = process.StandardError.ReadToEndAsync();

                using var timeoutCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
                if (timeoutMs > 0)
                {
                    timeoutCts.CancelAfter(timeoutMs);
                }

                try
                {
                    await process.WaitForExitAsync(timeoutCts.Token);
                }
                catch (OperationCanceledException) when (timeoutCts.IsCancellationRequested && !cancellationToken.IsCancellationRequested)
                {
                    // Timed out (not caller-cancelled). Kill, collect whatever drained, flag TimedOut so
                    // callers can distinguish a timeout from a genuine parse/exec failure.
                    try { process.Kill(true); }
                    catch (Exception ex) when (ex is not OperationCanceledException && ex is not OutOfMemoryException && ex is not StackOverflowException)
                    {
                        _logger.LogDebug(ex, "Failed to kill timed-out process {FileName} {Args}", startInfo.FileName, startInfo.Arguments);
                    }
                    stdout = await SafeReadAsync(stdoutTask);
                    stderr = await SafeReadAsync(stderrTask);
                    _logger.LogWarning("Process timed out after {Timeout}ms: {FileName} {Args}", timeoutMs, startInfo.FileName, startInfo.Arguments);
                    return BuildResult(-1, stdout, stderr, timedOut: true);
                }

                // Exited within the timeout window; the pipes are closed so both reads complete now.
                stdout = await stdoutTask;
                stderr = await stderrTask;

                return BuildResult(process.ExitCode, stdout, stderr, timedOut: false);
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
                _logger.LogWarning("Process run cancelled for {File} {Args}", startInfo.FileName, startInfo.Arguments);
                return BuildResult(-1, stdout, string.IsNullOrEmpty(stderr) ? "OperationCanceled" : stderr + "\nOperationCanceled", timedOut: false);
            }
            catch (Exception ex) when (ex is not OperationCanceledException && ex is not OutOfMemoryException && ex is not StackOverflowException)
            {
                // Surface exception details in the returned stderr so callers get meaningful diagnostics.
                var errText = string.IsNullOrEmpty(stderr) ? ex.ToString() : stderr + "\n" + ex;
                _logger.LogWarning(ex, "Process runner threw an exception for {File} {Args}", startInfo.FileName, startInfo.Arguments);
                return BuildResult(-1, stdout, errText, timedOut: false);
            }
        }

        private static async Task<string> SafeReadAsync(Task<string> readTask)
        {
            try { return await readTask; }
            catch (Exception ex) when (ex is not OutOfMemoryException && ex is not StackOverflowException)
            {
                Debug.WriteLine($"SystemProcessRunner.SafeReadAsync failed: {ex.Message}");
                return string.Empty;
            }
        }

        // Redact env + caller-registered sensitive values from captured output before returning.
        private ProcessResult BuildResult(int exitCode, string stdout, string stderr, bool timedOut)
        {
            var sensitive = LogRedaction.GetSensitiveValuesFromEnvironment()
                .Concat(_transientSensitiveCounts.Keys)
                .Where(v => !string.IsNullOrEmpty(v));
            return new ProcessResult(
                exitCode,
                LogRedaction.RedactText(stdout, sensitive),
                LogRedaction.RedactText(stderr, sensitive),
                timedOut);
        }

        public Process StartProcess(ProcessStartInfo startInfo)
        {
            try
            {
                var process = new Process();
                process.StartInfo = startInfo;
                // Do not override startInfo properties like RedirectStandardOutput/Error or UseShellExecute - caller configures them.
                process.Start();
                return process;
            }
            catch (Exception ex) when (ex is not OperationCanceledException && ex is not OutOfMemoryException && ex is not StackOverflowException)
            {
                _logger.LogWarning(ex, "Failed to start process {File} {Args}", startInfo.FileName, startInfo.Arguments);
                throw;
            }
        }

        public IDisposable RegisterTransientSensitive(IEnumerable<string> values)
        {
            if (values == null) return new DisposableAction(() => { });

            var added = new List<string>();
            foreach (var v in values.Where(x => !string.IsNullOrEmpty(x)))
            {
                _transientSensitiveCounts.AddOrUpdate(v!, 1, (_, old) => old + 1);
                added.Add(v!);
            }

            return new DisposableAction(() =>
            {
                foreach (var v in added)
                {
                    _transientSensitiveCounts.AddOrUpdate(v, 0, (_, old) => Math.Max(0, old - 1));
                    if (_transientSensitiveCounts.TryGetValue(v, out var cnt) && cnt == 0)
                    {
                        _transientSensitiveCounts.TryRemove(v, out _);
                    }
                }
            });
        }

        private class DisposableAction : IDisposable
        {
            private readonly Action _action;
            private bool _disposed;
            public DisposableAction(Action action) => _action = action ?? (() => { });
            public void Dispose()
            {
                if (_disposed) return;
                _disposed = true;
                try { _action(); }
                catch (Exception ex) when (ex is not OperationCanceledException && ex is not OutOfMemoryException && ex is not StackOverflowException)
                {
                    Debug.WriteLine($"SystemProcessRunner.DisposableAction cleanup failed: {ex.Message}");
                }
            }
        }
    }
}

