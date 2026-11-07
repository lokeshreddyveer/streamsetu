using System.IO.Compression;
using StreamSetu.Core;
using Xunit;

namespace StreamSetu.Core.Tests;

public sealed class PersonalTests : IDisposable
{
    private readonly string _dir = Path.Combine(Path.GetTempPath(), "streamsetu-test-" + Guid.NewGuid().ToString("N"));
    private DateTimeOffset _clock = new(2026, 11, 7, 12, 0, 0, TimeSpan.Zero);
    public void Dispose() { foreach (var d in Directory.GetDirectories(Path.GetTempPath(), Path.GetFileName(_dir) + "*")) try { Directory.Delete(d, true); } catch (IOException) { } }

    private ProfileManager Profiles() => new(new LocalStore(_dir), () => _clock);

    // ----- PINs and profiles -----

    [Fact]
    public void A_PIN_is_4_to_8_digits_and_is_stored_as_a_salted_hash()
    {
        Assert.True(PinHash.IsValid("1234")); Assert.True(PinHash.IsValid("12345678"));
        Assert.False(PinHash.IsValid("123")); Assert.False(PinHash.IsValid("123456789")); Assert.False(PinHash.IsValid("12a4")); Assert.False(PinHash.IsValid(null));
        var a = PinHash.Make("4821"); var b = PinHash.Make("4821");
        Assert.NotEqual(a.Hash, b.Hash);                         // a different salt each time
        Assert.True(a.Matches("4821")); Assert.False(a.Matches("4822")); Assert.False(a.Matches("")); Assert.False(new PinHash("not base64!", "x").Matches("4821"));
        Assert.Throws<ArgumentException>(() => PinHash.Make("12"));
    }

    [Fact]
    public void The_PIN_itself_is_never_written_to_disk()
    {
        var p = Profiles(); p.SetPin("main", "7391");
        foreach (var f in Directory.GetFiles(_dir, "*.json", SearchOption.AllDirectories)) Assert.DoesNotContain("7391", File.ReadAllText(f));
    }

    [Fact]
    public void There_is_always_one_profile_and_at_most_four_with_distinct_names()
    {
        var p = Profiles();
        Assert.Equal("Me", Assert.Single(p.All()).Name);
        Assert.Throws<InvalidOperationException>(() => p.Remove("main"));
        p.Add("Asha", false); p.Add("Kids", true); p.Add("Guest", false);
        Assert.Throws<InvalidOperationException>(() => p.Add("Fifth", false));
        p.Remove(p.All()[3].Id);
        Assert.Throws<InvalidOperationException>(() => p.Add("asha", false));
        Assert.Throws<ArgumentException>(() => p.Add("  ", false));
        Assert.True(p.All().Single(x => x.Name == "Kids").Kids);
    }

    [Fact]
    public void Each_profile_has_its_own_favourites_and_history_and_removing_one_deletes_them()
    {
        var p = Profiles(); var kid = p.Add("Kid", true);
        p.StoreOf("main").ToggleFavorite("x"); p.StoreOf(kid.Id).ToggleFavorite("y");
        Assert.Equal(new[] { "x" }, p.StoreOf("main").Favorites()); Assert.Equal(new[] { "y" }, p.StoreOf(kid.Id).Favorites());
        var folder = p.StoreOf(kid.Id).Folder; Assert.True(Directory.Exists(folder));
        p.Remove(kid.Id); Assert.False(Directory.Exists(folder));
        Assert.Throws<ArgumentException>(() => p.StoreOf(kid.Id));
    }

    [Fact]
    public void Five_wrong_PINs_lock_it_for_a_minute_and_the_count_survives_a_restart()
    {
        var p = Profiles(); p.SetPin("main", "1234");
        Assert.Equal(PinResult.Wrong, p.CheckPin("main", "0000"));
        for (int i = 0; i < 3; i++) Assert.Equal(PinResult.Wrong, p.CheckPin("main", "0000"));
        Assert.Equal(PinResult.Locked, Profiles().CheckPin("main", "0000"));                    // the fifth, from a freshly started app
        Assert.Equal(PinResult.Locked, Profiles().CheckPin("main", "1234"));                    // even the right one is refused while locked
        _clock = _clock.AddSeconds(61);
        Assert.Equal(PinResult.Ok, Profiles().CheckPin("main", "1234"));
        Assert.Equal(PinResult.Wrong, Profiles().CheckPin("main", "0000"));                     // and the count began again at zero
    }

    [Fact]
    public void A_right_PIN_resets_the_count_and_a_profile_without_one_says_so()
    {
        var p = Profiles(); Assert.Equal(PinResult.NoPin, p.CheckPin("main", "1234"));
        p.SetPin("main", "1234");
        for (int i = 0; i < 4; i++) p.CheckPin("main", "0000");
        Assert.Equal(PinResult.Ok, p.CheckPin("main", "1234"));
        for (int i = 0; i < 4; i++) Assert.Equal(PinResult.Wrong, p.CheckPin("main", "0000"));
        p.SetPin("main", null); Assert.Equal(PinResult.NoPin, p.CheckPin("main", "1234"));
    }

    // ----- Folders -----

    [Fact]
    public void Folders_can_be_hidden_renamed_and_reordered_and_it_is_remembered()
    {
        var store = new LocalStore(_dir); var f = new FolderPrefs(store);
        var groups = new[] { "UK", "US", "News", "Sport" };
        f.Hide("live", "US", true); f.Rename("live", "News", "Headlines");
        f.MoveDown("live", groups, "UK");                                          // UK, US, News, Sport -> US, UK, ...
        var view = new FolderPrefs(new LocalStore(_dir)).Visible("live", groups, false);
        Assert.Equal(new[] { "UK", "Headlines", "Sport" }, view.Select(v => v.Display).ToArray());   // US is hidden, so UK now follows it invisibly
        Assert.Equal("News", view[1].Name);
        f.Hide("live", "US", false); Assert.Equal("US", new FolderPrefs(store).Visible("live", groups, false)[0].Name);
    }

    [Fact]
    public void Moving_the_first_folder_up_or_the_last_down_does_nothing_and_new_folders_come_last()
    {
        var f = new FolderPrefs(new LocalStore(_dir));
        f.MoveUp("v", new[] { "A", "B" }, "A"); f.MoveDown("v", new[] { "A", "B" }, "B");
        Assert.Equal(new[] { "A", "B" }, f.Visible("v", new[] { "A", "B" }, false).Select(x => x.Name).ToArray());
        f.MoveDown("v", new[] { "A", "B" }, "A");
        Assert.Equal(new[] { "B", "A", "C" }, f.Visible("v", new[] { "A", "B", "C" }, false).Select(x => x.Name).ToArray());
    }

    [Fact]
    public void A_locked_folder_opens_only_with_its_PIN_is_hidden_from_Kids_and_cannot_be_reset_without_it()
    {
        var f = new FolderPrefs(new LocalStore(_dir)); var groups = new[] { "Family", "Adult" };
        f.SetLock("movie", "Adult", "2468");
        Assert.True(f.IsLocked("movie", "Adult")); Assert.False(f.IsLocked("movie", "Family"));
        Assert.True(f.Unlock("movie", "Adult", "2468")); Assert.False(f.Unlock("movie", "Adult", "1111")); Assert.False(f.Unlock("movie", "Family", "2468"));
        Assert.Equal(new[] { "Family", "Adult" }, f.Visible("movie", groups, false).Select(v => v.Name).ToArray());
        Assert.True(f.Visible("movie", groups, false)[1].Locked);
        Assert.Equal(new[] { "Family" }, f.Visible("movie", groups, true).Select(v => v.Name).ToArray());       // Kids never see it
        Assert.False(f.Reset("movie", "Adult", null)); Assert.False(f.Reset("movie", "Adult", "0000")); Assert.True(f.IsLocked("movie", "Adult"));
        Assert.True(f.Reset("movie", "Adult", "2468")); Assert.False(f.IsLocked("movie", "Adult"));
    }

    // ----- Collections, queue -----

    [Fact]
    public void Collections_are_created_filled_renamed_and_deleted()
    {
        var c = new Collections(new LocalStore(_dir));
        var heist = c.Create("Heist films");
        Assert.True(c.Add(heist.Id, "p|movie:1")); Assert.False(c.Add(heist.Id, "p|movie:1")); Assert.False(c.Add("nope", "k"));
        Assert.Throws<InvalidOperationException>(() => c.Create("heist FILMS")); Assert.Throws<ArgumentException>(() => c.Create(" "));
        c.Rename(heist.Id, "Heists"); Assert.Equal("Heists", new Collections(new LocalStore(_dir)).All().Single().Name);
        Assert.Equal(new[] { "p|movie:1" }, c.All().Single().Keys);
        c.Remove(heist.Id, "p|movie:1"); Assert.Empty(c.All().Single().Keys);
        c.Delete(heist.Id); Assert.Empty(c.All());
    }

    [Fact]
    public void The_queue_plays_next_first_adds_to_the_end_and_never_repeats_an_entry()
    {
        var q = new PlayQueue(); PlayQueue.Entry E(string k) => new(k, k, "http://h/" + k);
        q.Add(E("a")); q.Add(E("b")); q.Add(E("a")); q.PlayNext(E("c")); q.PlayNext(E("b"));
        Assert.Equal(new[] { "b", "c", "a" }, q.Items.Select(x => x.Key).ToArray());
        Assert.Equal("b", q.Next()!.Key); q.Remove("a"); Assert.Equal("c", q.Next()!.Key); Assert.Null(q.Next());
        q.Add(E("z")); q.Clear(); Assert.Empty(q.Items);
    }

    // ----- Filters and smart lists -----

    private static Item M(string id, string title, int? year, double? rating) => new() { Id = id, Kind = Kind.Movie, Title = title, Group = "G", Year = year, Rating = rating };

    [Fact]
    public void Filters_by_language_quality_rating_decade_and_watch_status()
    {
        var items = new[] { M("1", "EN | Heat 4K", 1995, 4.5), M("2", "FR | Le Film HD", 2003, 3.0), M("3", "EN | Old Film SD", 1962, 2.0), M("4", "EN | Heat Again 1080p", 1999, 4.0) };
        string Key(Item i) => "p|" + i.Id; var watched = new HashSet<string> { "p|1" };
        bool Started(string k) => k == "p|4";
        List<string> Ids(ItemFilter f) => f.Apply(items, Key, watched, Started).Select(i => i.Id).ToList();
        Assert.Equal(new[] { "1", "3", "4" }, Ids(new ItemFilter(Language: "english")));
        Assert.Equal(new[] { "1", "4" }, Ids(new ItemFilter(MinQuality: Quality.Hd1080)));
        Assert.Equal(new[] { "1", "4" }, Ids(new ItemFilter(MinRating: 4)));
        Assert.Equal(new[] { "1", "4" }, Ids(new ItemFilter(Decade: 1990)));
        Assert.Equal(new[] { "2", "3", "4" }, Ids(new ItemFilter(Status: WatchStatus.Unwatched)));
        Assert.Equal(new[] { "4" }, Ids(new ItemFilter(Status: WatchStatus.Started)));
        Assert.Equal(new[] { "4" }, Ids(new ItemFilter(Language: "English", Decade: 1990, Status: WatchStatus.Started)));
        Assert.Equal(4, Ids(new ItemFilter()).Count);
    }

    [Fact]
    public void Smart_lists_pick_unwatched_unwatched_favourites_and_recently_added()
    {
        var now = _clock;
        var items = new[]
        {
            M("1", "A", 2020, null) with { Added = now.AddDays(-3) }, M("2", "B", 2020, null) with { Added = now.AddDays(-40) },
            M("3", "C", 2020, null), M("4", "D", 2020, null) with { Added = now.AddDays(-1) }, M("5", "E", 2020, null) with { Added = now.AddDays(2) },
        };
        string Key(Item i) => i.Id; var watched = new HashSet<string> { "1" }; var favs = new HashSet<string> { "1", "2", "3" };
        Assert.Equal(new[] { "2", "3", "4", "5" }, SmartLists.Unwatched(items, Key, watched).Select(i => i.Id).ToArray());
        Assert.Equal(new[] { "2", "3" }, SmartLists.UnwatchedFavorites(items, Key, watched, favs).Select(i => i.Id).ToArray());
        Assert.Equal(new[] { "4", "1" }, SmartLists.AddedWithin(items, now, 30).Select(i => i.Id).ToArray());        // newest first; undated and future ones left out
    }

    // ----- Backup -----

    [Fact]
    public void A_backup_restores_the_data_and_keeps_what_it_replaced()
    {
        var data = Path.Combine(_dir, "data"); var s = new LocalStore(data);
        s.AddPlaylist(new Playlist("a", "A", PlaylistKind.M3u, "http://h")); s.ToggleFavorite("x");
        var zip = Path.Combine(_dir, "b.zip"); Backup.Export(data, zip);
        s.AddPlaylist(new Playlist("b", "B", PlaylistKind.M3u, "http://h2")); s.ToggleFavorite("y");
        var before = Backup.Restore(zip, data);
        var back = new LocalStore(data);
        Assert.Equal("A", Assert.Single(back.Playlists()).Name); Assert.Equal(new[] { "x" }, back.Favorites());
        Assert.Equal(2, new LocalStore(before).Playlists().Count);                  // the replaced data is still there
    }

    private string Zip(params (string Name, string Content)[] entries)
    {
        Directory.CreateDirectory(_dir); var path = Path.Combine(_dir, Guid.NewGuid().ToString("N") + ".zip");
        using var z = ZipFile.Open(path, ZipArchiveMode.Create);
        foreach (var (name, content) in entries) { using var w = new StreamWriter(z.CreateEntry(name).Open()); w.Write(content); }
        return path;
    }

    [Theory]
    [InlineData("../evil.json")] [InlineData("a/../../evil.json")] [InlineData("/etc/evil.json")] [InlineData("C:/evil.json")] [InlineData("a\\evil.json")] [InlineData("run.exe")] [InlineData("a/b/c/d.json")]
    public void A_backup_with_a_path_trick_or_a_file_that_is_not_data_is_refused_before_anything_changes(string name)
    {
        var data = Path.Combine(_dir, "data"); new LocalStore(data).ToggleFavorite("keep");
        var zip = Zip(("Favorites.json", "[]"), (name, "[]"));
        Assert.Throws<InvalidOperationException>(() => Backup.Restore(zip, data));
        Assert.Equal(new[] { "keep" }, new LocalStore(data).Favorites());          // untouched
        Assert.Empty(Directory.GetDirectories(_dir, "data.restoring-*"));          // and no half-extracted leftovers
    }

    [Fact]
    public void A_backup_with_a_damaged_file_is_refused()
    {
        var data = Path.Combine(_dir, "data"); new LocalStore(data).ToggleFavorite("keep");
        Assert.Throws<InvalidOperationException>(() => Backup.Restore(Zip(("Favorites.json", "{ not json")), data));
        Assert.Equal(new[] { "keep" }, new LocalStore(data).Favorites());
    }

    [Fact]
    public void A_backup_with_far_too_many_files_is_refused()
    {
        var entries = Enumerable.Range(0, Backup.MaxEntries + 1).Select(i => ($"f{i}.json", "[]")).ToArray();
        Assert.Throws<InvalidOperationException>(() => Backup.Restore(Zip(entries), Path.Combine(_dir, "data")));
    }
}
