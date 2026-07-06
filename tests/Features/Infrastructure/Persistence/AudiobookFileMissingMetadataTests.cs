/*
 * Listenarr - Audiobook Management System
 * Copyright (C) 2024-2026 Listenarr Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Affero General Public License as published
 * by the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */
using Microsoft.EntityFrameworkCore;
using Listenarr.Infrastructure.Persistence.Repositories;
using Listenarr.Tests.Builders;

namespace Listenarr.Tests.Features.Infrastructure.Persistence
{
    // #737: download-imported files can be persisted with DurationSeconds=0.0 (not null) and null
    // Codec/Bitrate. The metadata-rescan candidate query must select them so the background job
    // re-probes and heals them; otherwise they stay quality-unknown forever.
    public class AudiobookFileMissingMetadataTests
    {
        private static ListenArrDbContext NewDb() => new(
            new DbContextOptionsBuilder<ListenArrDbContext>()
                .UseInMemoryDatabase(Guid.NewGuid().ToString())
                .Options);

        [Fact]
        public async Task GetMissingMetadata_SelectsCodecNullAndZeroDuration_Rows()
        {
            using var db = NewDb();
            var book = new Audiobook { Title = "B", Monitored = true };
            db.Audiobooks.Add(book);
            await db.SaveChangesAsync();

            // Broken download row: has Format/SampleRate/Duration-column-set, but Codec/Bitrate null
            // and DurationSeconds == 0 (the exact shape observed in the DB).
            var broken = new AudiobookFileBuilder().WithAudiobook(book).WithPath("C:\\b\\dl.mp3")
                .WithFormat("mp3").WithSampleRate(44100).Build();
            broken.DurationSeconds = 0.0;   // zero, NOT null
            broken.Codec = null;
            broken.Bitrate = null;

            // Healthy row: fully populated, must NOT be selected.
            var good = new AudiobookFileBuilder().WithAudiobook(book).WithPath("C:\\b\\ok.mp3")
                .WithFormat("mp3").WithSampleRate(44100).WithCoded("mp3").WithBitrate(128000).Build();
            good.DurationSeconds = 3600.0;

            db.AudiobookFiles.AddRange(broken, good);
            await db.SaveChangesAsync();

            var repo = new EfAudiobookFileRepository(db);
            var candidates = await repo.GetMissingMetadataAsync(20);

            var paths = candidates.Select(c => c.Path).ToList();
            Assert.Contains("C:\\b\\dl.mp3", paths);      // broken row selected for re-probe
            Assert.DoesNotContain("C:\\b\\ok.mp3", paths); // healthy row left alone
        }
    }
}
