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

using System.Text;

namespace Listenarr.Api.DevTools
{
    /// <summary>
    /// SIDELOADED AI debug log sink (its own self-contained class). A dev-only telemetry endpoint so an AI
    /// assistant can SEE runtime behaviour directly instead of the user copying console output. The frontend
    /// POSTs structured trace events (JSON) to <c>/ai-log</c> and we APPEND them to ONE file
    /// (<c>&lt;contentRoot&gt;/ai-debug-log.jsonl</c>) = a single continuous timeline that survives reloads and
    /// navigations and that the AI reads straight off disk.
    ///
    /// Contract:
    ///   POST   /ai-log   body = JSON (array of events or one event) -> appended as one line, 204.
    ///   DELETE /ai-log                                              -> truncate the file, 204.
    ///   GET    /ai-log                                              -> stream the file back (ndjson).
    ///
    /// Inert unless env <c>LISTENARR_AI_LOG=1</c> (run-instance.ps1 sets it for the DEV instance only), so it
    /// never runs on LIVE. Registered FIRST in the pipeline (see Program.cs) so it short-circuits before the
    /// auth / antiforgery middleware and needs no tokens. Drop-in: this one class + one app.UseMiddleware line;
    /// delete both to remove entirely.
    /// </summary>
    public sealed class AiDebugLogMiddleware
    {
        private const string Route = "/ai-log";
        private const long MaxBytes = 8_000_000; // truncate a runaway log rather than fill the disk

        private static readonly object Gate = new();

        private readonly RequestDelegate _next;
        private readonly bool _enabled;
        private readonly string _logPath;

        public AiDebugLogMiddleware(RequestDelegate next, IWebHostEnvironment env)
        {
            _next = next;
            _enabled = string.Equals(
                Environment.GetEnvironmentVariable("LISTENARR_AI_LOG"), "1", StringComparison.Ordinal);

            // Prefer the explicit content root the test-instance launcher sets (_DevData); fall back to the
            // host content root so the file lands next to the instance's data either way.
            var root = Environment.GetEnvironmentVariable("LISTENARR_CONTENT_ROOT");
            if (string.IsNullOrWhiteSpace(root)) root = env.ContentRootPath;
            _logPath = Path.Combine(root, "ai-debug-log.jsonl");
        }

        public async Task InvokeAsync(HttpContext context)
        {
            if (!_enabled || !context.Request.Path.Equals(Route, StringComparison.OrdinalIgnoreCase))
            {
                await _next(context);
                return;
            }

            if (HttpMethods.IsPost(context.Request.Method))
            {
                string body;
                using (var reader = new StreamReader(context.Request.Body, Encoding.UTF8))
                {
                    body = await reader.ReadToEndAsync();
                }

                if (!string.IsNullOrWhiteSpace(body))
                {
                    lock (Gate)
                    {
                        try
                        {
                            var fi = new FileInfo(_logPath);
                            if (fi.Exists && fi.Length > MaxBytes)
                            {
                                File.Delete(_logPath);
                            }
                        }
                        catch { /* best-effort truncation */ }

                        File.AppendAllText(_logPath, body.Trim() + "\n");
                    }
                }

                context.Response.StatusCode = StatusCodes.Status204NoContent;
                return;
            }

            if (HttpMethods.IsDelete(context.Request.Method))
            {
                lock (Gate)
                {
                    try
                    {
                        if (File.Exists(_logPath))
                        {
                            File.Delete(_logPath);
                        }
                    }
                    catch { /* ignore */ }
                }

                context.Response.StatusCode = StatusCodes.Status204NoContent;
                return;
            }

            // GET: hand the whole timeline back over HTTP too (handy for quick inspection).
            if (File.Exists(_logPath))
            {
                context.Response.ContentType = "application/x-ndjson";
                await context.Response.SendFileAsync(_logPath);
            }
            else
            {
                context.Response.StatusCode = StatusCodes.Status204NoContent;
            }
        }
    }
}
