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

using System.Diagnostics;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;

namespace Listenarr.ServiceHost;

/// <summary>
/// Launches Listenarr.Api.exe as a child process and keeps it running. StartAsync (inherited from
/// BackgroundService) returns immediately - the SCM sees "started" without waiting on the app's own
/// startup, so however long the app takes to come up, the service itself never times out.
/// </summary>
public sealed class ProcessSupervisorService(ILogger<ProcessSupervisorService> logger) : BackgroundService
{
    private static readonly TimeSpan MinRestartDelay = TimeSpan.FromSeconds(2);
    private static readonly TimeSpan MaxRestartDelay = TimeSpan.FromSeconds(60);

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        var targetExe = ResolveTargetExePath();
        logger.LogInformation("ProcessSupervisorService starting. Target: {TargetExe}", targetExe);

        var restartDelay = MinRestartDelay;

        while (!stoppingToken.IsCancellationRequested)
        {
            var startedAt = DateTimeOffset.UtcNow;
            Process? process = null;

            try
            {
                process = Process.Start(new ProcessStartInfo
                {
                    FileName = targetExe,
                    WorkingDirectory = Path.GetDirectoryName(targetExe),
                    UseShellExecute = false,
                    CreateNoWindow = true,
                });

                logger.LogInformation("Launched {TargetExe} (pid {Pid})", targetExe, process?.Id);

                if (process is not null)
                {
                    await process.WaitForExitAsync(stoppingToken);
                    logger.LogWarning("{TargetExe} exited with code {ExitCode}", targetExe, process.ExitCode);
                }
            }
            catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
            {
                // Service is stopping - kill the child (if still alive) and exit the loop cleanly.
                TryKill(process);
                break;
            }
            catch (Exception ex) when (ex is not OutOfMemoryException && ex is not StackOverflowException)
            {
                logger.LogError(ex, "Failed to launch or monitor {TargetExe}", targetExe);
            }

            if (stoppingToken.IsCancellationRequested)
            {
                TryKill(process);
                break;
            }

            // Ran for a while before dying -> treat as a fresh failure (reset backoff). Died
            // immediately, repeatedly -> back off further each time so a crash loop doesn't hammer
            // the machine/DB/ffprobe.
            restartDelay = DateTimeOffset.UtcNow - startedAt > TimeSpan.FromMinutes(1)
                ? MinRestartDelay
                : TimeSpan.FromSeconds(Math.Min(restartDelay.TotalSeconds * 2, MaxRestartDelay.TotalSeconds));

            logger.LogInformation("Restarting {TargetExe} in {Delay}", targetExe, restartDelay);

            try
            {
                await Task.Delay(restartDelay, stoppingToken);
            }
            catch (OperationCanceledException)
            {
                break;
            }
        }

        logger.LogInformation("ProcessSupervisorService stopping");
    }

    private static void TryKill(Process? process)
    {
        if (process is null) return;
        try
        {
            if (!process.HasExited) process.Kill(entireProcessTree: true);
        }
        catch
        {
            // Best-effort; the process may have already exited between the check and the kill.
        }
    }

    /// <summary>
    /// Listenarr.Api.exe is deployed as a sibling of this wrapper (same bin\ folder). Override via
    /// LISTENARR_SERVICEHOST_TARGET_EXE for local testing against a different location.
    /// </summary>
    private static string ResolveTargetExePath()
    {
        var overridePath = Environment.GetEnvironmentVariable("LISTENARR_SERVICEHOST_TARGET_EXE");
        if (!string.IsNullOrWhiteSpace(overridePath)) return overridePath;

        return Path.Combine(AppContext.BaseDirectory, "Listenarr.Api.exe");
    }
}
