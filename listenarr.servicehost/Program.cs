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

using Listenarr.ServiceHost;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;

// Not the app itself: this is a tiny, separate process whose only job is to be the thing the
// Windows Service Control Manager talks to. It reports "started" instantly (nothing here awaits
// anything before returning), then launches Listenarr.Api.exe as a plain child process, exactly
// like running it from a console - which is the one mode that has been reliable. If the child
// dies, this restarts it. No web framework, no HTTP - just process supervision.
var builder = Host.CreateApplicationBuilder(args);
builder.Services.AddWindowsService(options => options.ServiceName = "Listenarr");
builder.Services.AddHostedService<ProcessSupervisorService>();

var host = builder.Build();
host.Run();
