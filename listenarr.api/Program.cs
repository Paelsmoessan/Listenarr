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

using Listenarr.Api.Startup;
using Listenarr.Infrastructure.DependencyInjection;
using Listenarr.Infrastructure.FileSystem;
using Listenarr.Infrastructure.Realtime.DependencyInjection;

var realtimeLogSink = RealtimeLoggingExtensions.CreateListenarrRealtimeLogSink();
var bootstrapFileSystem = new LocalFileSystem();
var builder = ListenarrBuilderFactory.Create(args, realtimeLogSink, bootstrapFileSystem);

// Enable Windows Service hosting (SCM start/stop handshake). No-op when run from
// console or on Linux. Content root is already anchored to AppContext.BaseDirectory
// by ListenarrBuilderFactory, so config/ resolves next to the exe under the service.
builder.Host.UseWindowsService();

builder.AddListenarrApiServices(bootstrapFileSystem);
builder.Services.AddListenarrInfrastructureComposition(builder.Configuration, builder.Environment);

var app = builder.Build();

app.Services.ApplyListenarrDatabaseMigrations();
await app.RunListenarrStartupTasksAsync();

realtimeLogSink.InitializeListenarrRealtimeLogging(app.Services);

// Sideloaded dev-only AI debug log sink (inert unless LISTENARR_AI_LOG=1). Registered FIRST so it
// short-circuits /ai-log before auth/antiforgery. Remove this line + DevTools/AiDebugLogMiddleware.cs to delete.
app.UseMiddleware<Listenarr.Api.DevTools.AiDebugLogMiddleware>();

app.UseListenarrRequestPipeline(endpoints => endpoints.MapListenarrRealtimeHubs(app.Environment));

app.Run();
