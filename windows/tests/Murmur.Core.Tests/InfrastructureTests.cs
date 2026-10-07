using System.Text.Json;
using Murmur.Abstractions;
using Murmur.Core;
using Murmur.Testing;
using Shouldly;
using Xunit;

namespace Murmur.CoreTests;

/// <summary>The diagnostic log: structured, bounded, and free of user text.</summary>
public sealed class FileDiagnosticLogTests : IDisposable
{
    private readonly string _directory = Path.Combine(Path.GetTempPath(), $"fluence-log-{Guid.NewGuid():N}");

    public void Dispose()
    {
        if (Directory.Exists(_directory)) Directory.Delete(_directory, recursive: true);
    }

    [Fact]
    public void Each_event_is_one_parseable_json_line()
    {
        var log = new FileDiagnosticLog(_directory, new FakeClock());
        log.Error("capture.open_failed", new InvalidOperationException("device gone"),
            new Dictionary<string, object?> { ["attempt"] = 2, ["elapsed"] = TimeSpan.FromMilliseconds(40) });
        log.Info("startup");

        var lines = File.ReadAllLines(log.CurrentPath);
        lines.Length.ShouldBe(2);

        using var first = JsonDocument.Parse(lines[0]);
        first.RootElement.GetProperty("level").GetString().ShouldBe("error");
        first.RootElement.GetProperty("event").GetString().ShouldBe("capture.open_failed");
        first.RootElement.GetProperty("exception").GetString().ShouldBe("System.InvalidOperationException");
        first.RootElement.GetProperty("attempt").GetInt32().ShouldBe(2);
        first.RootElement.GetProperty("elapsed").GetDouble().ShouldBe(40);
    }

    [Fact]
    public void The_log_rotates_instead_of_growing_forever()
    {
        var log = new FileDiagnosticLog(_directory, new FakeClock());
        var padding = new Dictionary<string, object?> { ["pad"] = new string('x', 4096) };

        for (var i = 0; i < 600; i++) log.Info("tick", padding);

        var files = Directory.GetFiles(_directory);
        files.Length.ShouldBeLessThanOrEqualTo(FileDiagnosticLog.KeptFiles);
        foreach (var file in files)
        {
            new FileInfo(file).Length.ShouldBeLessThan(FileDiagnosticLog.MaxBytes + 8192);
        }
    }

    [Fact]
    public void An_unwritable_log_never_throws()
    {
        // A file where the directory should be: every write fails.
        File.WriteAllText(_directory, "not a directory");
        try
        {
            Should.NotThrow(() => new FileDiagnosticLog(_directory).Error("x", new IOException()));
        }
        finally
        {
            File.Delete(_directory);
        }
    }
}

/// <summary>All-or-nothing file replacement.</summary>
public sealed class AtomicFileTests : IDisposable
{
    private readonly string _directory = Path.Combine(Path.GetTempPath(), $"fluence-atomic-{Guid.NewGuid():N}");

    public void Dispose()
    {
        if (Directory.Exists(_directory)) Directory.Delete(_directory, recursive: true);
    }

    [Fact]
    public void Replaces_contents_and_leaves_no_temporary_files()
    {
        var path = Path.Combine(_directory, "settings.json");
        AtomicFile.WriteAllText(path, "one");
        AtomicFile.WriteAllText(path, "two");

        File.ReadAllText(path).ShouldBe("two");
        Directory.GetFiles(_directory).ShouldHaveSingleItem();
    }

    [Fact]
    public void TryCreate_never_overwrites()
    {
        var path = Path.Combine(_directory, "history.key");

        AtomicFile.TryCreate(path, [1, 2, 3]).ShouldBeTrue();
        AtomicFile.TryCreate(path, [9, 9, 9]).ShouldBeFalse();

        File.ReadAllBytes(path).ShouldBe(new byte[] { 1, 2, 3 });
        Directory.GetFiles(_directory).ShouldHaveSingleItem();
    }

    [Fact]
    public void Writes_utf8_without_a_byte_order_mark()
    {
        var path = Path.Combine(_directory, "dictionary.txt");
        AtomicFile.WriteAllText(path, "é");

        File.ReadAllBytes(path).ShouldBe(new byte[] { 0xC3, 0xA9 });
    }
}
