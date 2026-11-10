// Night City Trainer launcher: finds Cyberpunk 2077, installs Cyber Engine Tweaks
// and the trainer, keeps the trainer up to date, and starts the game.
// Built with the C# compiler that ships with Windows (see build.ps1).

using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Net;
using System.Reflection;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Markup;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Microsoft.Win32;
using IOPath = System.IO.Path;

namespace NightCityTrainer
{
    public class GameInstall
    {
        public string Path;
        public string Store;        // Steam, GOG, Epic or Manual
        public string EpicAppName;  // only for Epic installs
    }

    public class UpdateInfo
    {
        public Version Version;
        public string Url;
    }

    // Everything that touches the disk or the network. No UI in here.
    public static class Core
    {
        const string SteamAppId = "1091500";
        const string CetApi = "https://api.github.com/repos/maximegmd/CyberEngineTweaks/releases/latest";
        const string CetDownloadPrefix = "https://github.com/maximegmd/CyberEngineTweaks/releases/download/";
        const string UserAgent = "NightCityTrainerLauncher";

        public static string SettingsFile
        {
            get
            {
                string dir = IOPath.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "NightCityTrainer");
                return IOPath.Combine(dir, "game-folder.txt");
            }
        }

        // ---- Finding the game -------------------------------------------------

        public static bool IsGameFolder(string path)
        {
            if (string.IsNullOrEmpty(path)) return false;
            try { return File.Exists(IOPath.Combine(path, "bin", "x64", "Cyberpunk2077.exe")); }
            catch { return false; }
        }

        public static GameInstall DetectGame()
        {
            try
            {
                if (File.Exists(SettingsFile))
                {
                    string saved = File.ReadAllText(SettingsFile).Trim();
                    if (IsGameFolder(saved)) return Describe(saved);
                }
            }
            catch { }

            foreach (string library in SteamLibraries())
            {
                string path = IOPath.Combine(library, "steamapps", "common", "Cyberpunk 2077");
                if (IsGameFolder(path)) return new GameInstall { Path = path, Store = "Steam" };
            }

            string gog = RegistryString(Registry.LocalMachine,
                @"SOFTWARE\WOW6432Node\GOG.com\Games\1423049311", "path");
            if (IsGameFolder(gog)) return new GameInstall { Path = gog, Store = "GOG" };

            GameInstall epic = FindEpic(null);
            if (epic != null) return epic;

            return null;
        }

        // Works out which store a folder belongs to, so the game is launched the right way.
        public static GameInstall Describe(string path)
        {
            string full = IOPath.GetFullPath(path).TrimEnd('\\');
            if (full.IndexOf(@"\steamapps\common\", StringComparison.OrdinalIgnoreCase) >= 0)
                return new GameInstall { Path = full, Store = "Steam" };
            GameInstall epic = FindEpic(full);
            if (epic != null) return epic;
            return new GameInstall { Path = full, Store = "Manual" };
        }

        static IEnumerable<string> SteamLibraries()
        {
            var roots = new List<string>();
            string hkcu = RegistryString(Registry.CurrentUser, @"Software\Valve\Steam", "SteamPath");
            string hklm = RegistryString(Registry.LocalMachine, @"SOFTWARE\WOW6432Node\Valve\Steam", "InstallPath");
            if (!string.IsNullOrEmpty(hkcu)) roots.Add(hkcu.Replace('/', '\\'));
            if (!string.IsNullOrEmpty(hklm)) roots.Add(hklm);
            roots.Add(@"C:\Program Files (x86)\Steam");

            var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (string root in roots)
            {
                if (seen.Add(root)) yield return root;
                string vdf = IOPath.Combine(root, "steamapps", "libraryfolders.vdf");
                string text = null;
                try { if (File.Exists(vdf)) text = File.ReadAllText(vdf); } catch { }
                if (text == null) continue;
                foreach (Match m in Regex.Matches(text, "\"path\"\\s+\"([^\"]+)\""))
                {
                    string library = m.Groups[1].Value.Replace(@"\\", @"\");
                    if (seen.Add(library)) yield return library;
                }
            }
        }

        static GameInstall FindEpic(string onlyThisPath)
        {
            try
            {
                string dir = IOPath.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
                    "Epic", "EpicGamesLauncher", "Data", "Manifests");
                if (!Directory.Exists(dir)) return null;
                var json = new JavaScriptSerializer();
                foreach (string file in Directory.GetFiles(dir, "*.item"))
                {
                    var item = json.Deserialize<Dictionary<string, object>>(File.ReadAllText(file));
                    string name = Str(item, "DisplayName");
                    string location = Str(item, "InstallLocation");
                    if (name == null || location == null) continue;
                    if (name.IndexOf("Cyberpunk 2077", StringComparison.OrdinalIgnoreCase) < 0) continue;
                    if (!IsGameFolder(location)) continue;
                    string full = IOPath.GetFullPath(location).TrimEnd('\\');
                    if (onlyThisPath != null &&
                        !string.Equals(full, onlyThisPath, StringComparison.OrdinalIgnoreCase)) continue;
                    return new GameInstall { Path = full, Store = "Epic", EpicAppName = Str(item, "AppName") };
                }
            }
            catch { }
            return null;
        }

        static string RegistryString(RegistryKey hive, string key, string value)
        {
            try
            {
                using (RegistryKey k = hive.OpenSubKey(key))
                {
                    return k == null ? null : k.GetValue(value) as string;
                }
            }
            catch { return null; }
        }

        static string Str(Dictionary<string, object> map, string key)
        {
            object value;
            return map != null && map.TryGetValue(key, out value) ? value as string : null;
        }

        public static void RememberGameFolder(string path)
        {
            try
            {
                Directory.CreateDirectory(IOPath.GetDirectoryName(SettingsFile));
                File.WriteAllText(SettingsFile, path);
            }
            catch { }
        }

        public static bool IsGameRunning()
        {
            try { return Process.GetProcessesByName("Cyberpunk2077").Length > 0; }
            catch { return false; }
        }

        // ---- What is installed ------------------------------------------------

        static string PluginDir(string game)
        {
            return IOPath.Combine(game, "bin", "x64", "plugins");
        }

        public static string TrainerDir(string game)
        {
            return IOPath.Combine(PluginDir(game), "cyber_engine_tweaks", "mods", "NightCityTrainer");
        }

        public static bool CetInstalled(string game)
        {
            return File.Exists(IOPath.Combine(game, "bin", "x64", "version.dll"))
                && File.Exists(IOPath.Combine(PluginDir(game), "cyber_engine_tweaks.asi"));
        }

        public static Version ParseLuaVersion(string lua)
        {
            if (lua == null) return null;
            Match m = Regex.Match(lua, "version\\s*=\\s*\"(\\d+(?:\\.\\d+){1,3})\"");
            Version v;
            return m.Success && Version.TryParse(m.Groups[1].Value, out v) ? v : null;
        }

        public static Version InstalledTrainerVersion(string game)
        {
            try
            {
                string file = IOPath.Combine(TrainerDir(game), "init.lua");
                return File.Exists(file) ? ParseLuaVersion(File.ReadAllText(file)) : null;
            }
            catch { return null; }
        }

        public static string BundledLua()
        {
            using (Stream s = Assembly.GetExecutingAssembly().GetManifestResourceStream("init.lua"))
            using (var reader = new StreamReader(s, Encoding.UTF8))
            {
                return reader.ReadToEnd();
            }
        }

        // A trainer file must look like the trainer, not an error page.
        public static bool LooksLikeTrainer(string lua)
        {
            return lua != null && lua.Length > 2000 && lua.Length < 2000000
                && lua.Contains("registerForEvent") && lua.Contains("Night City Trainer")
                && ParseLuaVersion(lua) != null;
        }

        // ---- Network ----------------------------------------------------------

        static HttpWebRequest Request(string url)
        {
            if (!url.StartsWith("https://", StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("Only https downloads are allowed.");
            ServicePointManager.SecurityProtocol = (SecurityProtocolType)3072 | (SecurityProtocolType)12288;
            var request = (HttpWebRequest)WebRequest.Create(url);
            request.UserAgent = UserAgent;
            request.Timeout = 20000;
            request.ReadWriteTimeout = 30000;
            request.AutomaticDecompression = DecompressionMethods.GZip | DecompressionMethods.Deflate;
            return request;
        }

        static string DownloadText(string url)
        {
            using (var response = (HttpWebResponse)Request(url).GetResponse())
            using (var reader = new StreamReader(response.GetResponseStream(), Encoding.UTF8))
            {
                return reader.ReadToEnd();
            }
        }

        static void DownloadFile(string url, string target, Action<double> progress)
        {
            using (var response = (HttpWebResponse)Request(url).GetResponse())
            using (Stream input = response.GetResponseStream())
            using (FileStream output = File.Create(target))
            {
                long total = response.ContentLength;
                long done = 0;
                var buffer = new byte[81920];
                int read;
                while ((read = input.Read(buffer, 0, buffer.Length)) > 0)
                {
                    output.Write(buffer, 0, read);
                    done += read;
                    if (total > 0 && progress != null) progress((double)done / total);
                }
            }
        }

        // Asks the update server for the newest trainer. Returns null when there is
        // no update server configured.
        public static UpdateInfo CheckForUpdate()
        {
            if (string.IsNullOrEmpty(BuildInfo.UpdateManifestUrl)) return null;
            string text = DownloadText(BuildInfo.UpdateManifestUrl);
            var manifest = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(text);
            Version version;
            string url = Str(manifest, "url");
            if (!Version.TryParse(Str(manifest, "version") ?? "", out version) || string.IsNullOrEmpty(url))
                throw new InvalidDataException("The update information is not valid.");
            return new UpdateInfo { Version = version, Url = url };
        }

        public static string DownloadTrainer(UpdateInfo update)
        {
            string lua = DownloadText(update.Url);
            if (!LooksLikeTrainer(lua))
                throw new InvalidDataException("The downloaded update is not a valid trainer file.");
            return lua;
        }

        // ---- Installing -------------------------------------------------------

        public static void InstallCet(string game, Action<string, double> report)
        {
            report("Finding the latest Cyber Engine Tweaks...", 0);
            var release = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(DownloadText(CetApi));
            string url = null;
            object assets;
            if (release.TryGetValue("assets", out assets) && assets is IEnumerable)
            {
                foreach (object entry in (IEnumerable)assets)
                {
                    var asset = entry as Dictionary<string, object>;
                    string name = Str(asset, "name");
                    string link = Str(asset, "browser_download_url");
                    if (name != null && link != null && name.EndsWith(".zip", StringComparison.OrdinalIgnoreCase)
                        && link.StartsWith(CetDownloadPrefix, StringComparison.OrdinalIgnoreCase))
                    {
                        url = link;
                        break;
                    }
                }
            }
            if (url == null) throw new InvalidDataException("Could not find the Cyber Engine Tweaks download.");

            string zip = IOPath.Combine(IOPath.GetTempPath(), "nct_cet_" + Guid.NewGuid().ToString("N") + ".zip");
            try
            {
                DownloadFile(url, zip, p => report("Downloading Cyber Engine Tweaks...  " + (int)(p * 100) + "%", p * 0.85));
                report("Installing Cyber Engine Tweaks...", 0.9);
                ExtractInto(zip, game);
                report("Cyber Engine Tweaks installed", 1);
            }
            finally
            {
                try { File.Delete(zip); } catch { }
            }
        }

        // Unpacks a zip into a folder, refusing any entry that would land outside it.
        static void ExtractInto(string zipFile, string folder)
        {
            string root = IOPath.GetFullPath(folder).TrimEnd('\\') + "\\";
            using (ZipArchive archive = ZipFile.OpenRead(zipFile))
            {
                foreach (ZipArchiveEntry entry in archive.Entries)
                {
                    if (entry.FullName.EndsWith("/") || entry.FullName.EndsWith("\\")) continue;
                    string target = IOPath.GetFullPath(IOPath.Combine(root, entry.FullName));
                    if (!target.StartsWith(root, StringComparison.OrdinalIgnoreCase))
                        throw new InvalidDataException("The download contains an unsafe file path.");
                    Directory.CreateDirectory(IOPath.GetDirectoryName(target));
                    entry.ExtractToFile(target, true);
                }
            }
        }

        // Only init.lua is replaced, so each player's settings and saved spots are kept.
        public static void InstallTrainer(string game, string lua)
        {
            string dir = TrainerDir(game);
            Directory.CreateDirectory(dir);
            string target = IOPath.Combine(dir, "init.lua");
            string temp = target + ".new";
            File.WriteAllText(temp, lua, new UTF8Encoding(false));
            if (File.Exists(target)) File.Delete(target);
            File.Move(temp, target);
        }

        public static void UninstallTrainer(string game)
        {
            string dir = TrainerDir(game);
            if (Directory.Exists(dir)) Directory.Delete(dir, true);
        }

        // True when the player has other Cyber Engine Tweaks mods, which need CET to stay.
        public static bool HasOtherCetMods(string game)
        {
            try
            {
                string mods = IOPath.Combine(PluginDir(game), "cyber_engine_tweaks", "mods");
                if (!Directory.Exists(mods)) return false;
                foreach (string dir in Directory.GetDirectories(mods))
                {
                    if (!string.Equals(IOPath.GetFileName(dir), "NightCityTrainer",
                        StringComparison.OrdinalIgnoreCase)) return true;
                }
            }
            catch { }
            return false;
        }

        // Removes exactly the files Cyber Engine Tweaks installs, leaving the game unmodded.
        public static void UninstallCet(string game)
        {
            string bin = IOPath.Combine(game, "bin", "x64");
            string cetDir = IOPath.Combine(PluginDir(game), "cyber_engine_tweaks");
            if (Directory.Exists(cetDir)) Directory.Delete(cetDir, true);
            foreach (string file in new[] {
                IOPath.Combine(PluginDir(game), "cyber_engine_tweaks.asi"),
                IOPath.Combine(bin, "version.dll"),
                IOPath.Combine(bin, "global.ini") })
            {
                if (File.Exists(file)) File.Delete(file);
            }
            string plugins = PluginDir(game);
            if (Directory.Exists(plugins) && Directory.GetFileSystemEntries(plugins).Length == 0)
                Directory.Delete(plugins);
        }

        public static void LaunchGame(GameInstall game)
        {
            if (game.Store == "Steam")
            {
                Process.Start("steam://rungameid/" + SteamAppId);
            }
            else if (game.Store == "Epic" && !string.IsNullOrEmpty(game.EpicAppName))
            {
                Process.Start("com.epicgames.launcher://apps/" + Uri.EscapeDataString(game.EpicAppName)
                    + "?action=launch&silent=true");
            }
            else
            {
                string dir = IOPath.Combine(game.Path, "bin", "x64");
                var info = new ProcessStartInfo(IOPath.Combine(dir, "Cyberpunk2077.exe"));
                info.WorkingDirectory = dir;
                Process.Start(info);
            }
        }
    }

    public class LauncherWindow
    {
        enum Dot { Idle, Ok, Warn, Bad, Busy }

        readonly Window window;
        readonly Button mainButton, folderButton, removeButton;
        readonly TextBlock activity, valGame, valCet, valTrainer, valUpdate, tip;
        readonly System.Windows.Shapes.Ellipse dotGame, dotCet, dotTrainer, dotUpdate;
        readonly Border progressTrack, progressFill;

        readonly Dictionary<string, string> options;
        readonly Version bundledVersion;
        readonly string bundledLua;

        GameInstall game;
        UpdateInfo update;
        bool updateCheckFailed;
        bool busy;
        string mainAction = "";

        public LauncherWindow(Dictionary<string, string> options)
        {
            this.options = options;
            bundledLua = Core.BundledLua();
            bundledVersion = Core.ParseLuaVersion(bundledLua) ?? new Version(0, 0);

            using (Stream xaml = Assembly.GetExecutingAssembly().GetManifestResourceStream("Launcher.xaml"))
            {
                window = (Window)XamlReader.Load(xaml);
            }

            mainButton = Find<Button>("MainButton");
            folderButton = Find<Button>("FolderButton");
            removeButton = Find<Button>("RemoveButton");
            activity = Find<TextBlock>("Activity");
            valGame = Find<TextBlock>("ValGame");
            valCet = Find<TextBlock>("ValCet");
            valTrainer = Find<TextBlock>("ValTrainer");
            valUpdate = Find<TextBlock>("ValUpdate");
            tip = Find<TextBlock>("Tip");
            dotGame = Find<System.Windows.Shapes.Ellipse>("DotGame");
            dotCet = Find<System.Windows.Shapes.Ellipse>("DotCet");
            dotTrainer = Find<System.Windows.Shapes.Ellipse>("DotTrainer");
            dotUpdate = Find<System.Windows.Shapes.Ellipse>("DotUpdate");
            progressTrack = Find<Border>("ProgressTrack");
            progressFill = Find<Border>("ProgressFill");

            Find<TextBlock>("LauncherVersion").Text = "Launcher " + BuildInfo.LauncherVersion;
            Find<Grid>("TitleBar").MouseLeftButtonDown += delegate(object s, MouseButtonEventArgs e)
            {
                if (e.ButtonState == MouseButtonState.Pressed) window.DragMove();
            };
            Find<Button>("MinButton").Click += delegate { window.WindowState = WindowState.Minimized; };
            Find<Button>("CloseButton").Click += delegate { window.Close(); };
            mainButton.Click += delegate { OnMainButton(); };
            folderButton.Click += delegate { ChooseFolder(); };
            removeButton.Click += delegate { Uninstall(); };
            window.Loaded += delegate { Start(); };
        }

        public Window Window { get { return window; } }

        T Find<T>(string name) where T : class
        {
            T element = window.FindName(name) as T;
            if (element == null) throw new InvalidOperationException("Missing UI element: " + name);
            return element;
        }

        // ---- Startup ----------------------------------------------------------

        async void Start()
        {
            SetDot(dotGame, Dot.Busy);
            SetDot(dotUpdate, Dot.Busy);

            string forced;
            if (options.TryGetValue("game", out forced))
                game = Core.IsGameFolder(forced) ? Core.Describe(forced) : null;
            else
                game = await Task.Run(() => Core.DetectGame());

            try { update = await Task.Run(() => Core.CheckForUpdate()); }
            catch { updateCheckFailed = true; }

            Refresh();

            if (options.ContainsKey("install")) await InstallOrUpdate(false);
            if (options.ContainsKey("uninstall-all") && game != null)
            {
                Core.UninstallTrainer(game.Path);
                Core.UninstallCet(game.Path);
                Refresh();
            }
            if (options.ContainsKey("shot")) await SaveScreenshot(options["shot"]);
            if (options.ContainsKey("status")) File.WriteAllText(options["status"], DescribeState());
            if (options.ContainsKey("exit")) window.Close();
        }

        // ---- State ------------------------------------------------------------

        Version LatestVersion()
        {
            return update != null && update.Version > bundledVersion ? update.Version : bundledVersion;
        }

        void Refresh()
        {
            Version latest = LatestVersion();

            if (updateCheckFailed)
            {
                SetDot(dotUpdate, Dot.Warn);
                valUpdate.Text = "Couldn't check. Using built-in v" + bundledVersion;
            }
            else if (string.IsNullOrEmpty(BuildInfo.UpdateManifestUrl))
            {
                SetDot(dotUpdate, Dot.Idle);
                valUpdate.Text = "Built-in v" + bundledVersion + "  (online updates off)";
            }
            else
            {
                SetDot(dotUpdate, Dot.Ok);
                valUpdate.Text = "Latest version is v" + latest;
            }

            if (game == null)
            {
                SetDot(dotGame, Dot.Bad);
                valGame.Text = "Cyberpunk 2077 not found";
                valGame.ToolTip = null;
                SetDot(dotCet, Dot.Idle);
                valCet.Text = "-";
                SetDot(dotTrainer, Dot.Idle);
                valTrainer.Text = "-";
                activity.Text = "Choose the folder where Cyberpunk 2077 is installed.";
                SetMain("LOCATE CYBERPUNK 2077", "locate");
                removeButton.IsEnabled = false;
                return;
            }

            SetDot(dotGame, Dot.Ok);
            valGame.Text = (game.Store == "Manual" ? "" : game.Store + "  ·  ") + game.Path;
            valGame.ToolTip = game.Path;

            bool cet = Core.CetInstalled(game.Path);
            SetDot(dotCet, cet ? Dot.Ok : Dot.Warn);
            valCet.Text = cet ? "Installed" : "Not installed (will be downloaded)";

            Version installed = Core.InstalledTrainerVersion(game.Path);
            bool current = installed != null && installed >= latest;
            if (installed == null)
            {
                SetDot(dotTrainer, Dot.Warn);
                valTrainer.Text = "Not installed";
            }
            else
            {
                SetDot(dotTrainer, current ? Dot.Ok : Dot.Warn);
                valTrainer.Text = "v" + installed + (current ? "  (up to date)" : "  (update available)");
            }
            removeButton.IsEnabled = installed != null;

            if (!cet || installed == null)
            {
                activity.Text = "Ready to install. One click sets everything up.";
                SetMain("INSTALL", "install");
            }
            else if (!current)
            {
                activity.Text = "A new trainer version is ready.";
                SetMain("UPDATE TO v" + latest + " AND PLAY", "update-play");
            }
            else
            {
                activity.Text = "Everything is installed and up to date.";
                SetMain("PLAY CYBERPUNK 2077", "play");
            }
        }

        void SetMain(string text, string action)
        {
            mainButton.Content = text;
            mainAction = action;
            mainButton.IsEnabled = !busy;
        }

        void SetBusy(bool value)
        {
            busy = value;
            mainButton.IsEnabled = !value;
            folderButton.IsEnabled = !value;
            removeButton.IsEnabled = !value && game != null && Core.InstalledTrainerVersion(game.Path) != null;
            Fade(progressTrack, value ? 1 : 0, 250);
            if (!value) SetProgress(0, false);
        }

        string DescribeState()
        {
            var sb = new StringBuilder();
            sb.AppendLine("game=" + (game == null ? "none" : game.Store + "|" + game.Path));
            sb.AppendLine("cet=" + (game != null && Core.CetInstalled(game.Path)));
            sb.AppendLine("trainer=" + (game == null ? null : Core.InstalledTrainerVersion(game.Path)));
            sb.AppendLine("bundled=" + bundledVersion);
            sb.AppendLine("latest=" + LatestVersion());
            sb.AppendLine("updateCheckFailed=" + updateCheckFailed);
            sb.AppendLine("action=" + mainAction);
            sb.AppendLine("activity=" + activity.Text);
            return sb.ToString();
        }

        // ---- Actions ----------------------------------------------------------

        async void OnMainButton()
        {
            if (busy) return;
            if (mainAction == "locate") ChooseFolder();
            else if (mainAction == "install") await InstallOrUpdate(false);
            else if (mainAction == "update-play") await InstallOrUpdate(true);
            else if (mainAction == "play") Play();
        }

        async Task InstallOrUpdate(bool playAfter)
        {
            if (game == null || busy) return;
            string path = game.Path;
            bool needCet = !Core.CetInstalled(path);

            if (needCet && Core.IsGameRunning() && !options.ContainsKey("ignore-running"))
            {
                Fail("Close Cyberpunk 2077 first, then press Install again.");
                return;
            }

            SetBusy(true);
            try
            {
                if (needCet)
                {
                    SetDot(dotCet, Dot.Busy);
                    valCet.Text = "Installing...";
                    await Task.Run(() => Core.InstallCet(path, (text, p) => Ui(() =>
                    {
                        activity.Text = text;
                        SetProgress(0.05 + p * 0.75, true);
                    })));
                }

                SetDot(dotTrainer, Dot.Busy);
                valTrainer.Text = "Installing...";
                activity.Text = "Installing the trainer...";
                SetProgress(0.88, true);

                string lua = bundledLua;
                if (update != null && update.Version > bundledVersion)
                {
                    UpdateInfo target = update;
                    try { lua = await Task.Run(() => Core.DownloadTrainer(target)); }
                    catch { lua = bundledLua; }
                }
                await Task.Run(() => Core.InstallTrainer(path, lua));

                SetProgress(1, true);
                await Task.Delay(450);
                SetBusy(false);
                Refresh();

                if (needCet)
                {
                    tip.Text = "First launch: Cyber Engine Tweaks asks you to pick a key. "
                        + "That key opens the trainer menu in game.";
                }
                else if (Core.IsGameRunning())
                {
                    tip.Text = "The game is running. Open the Cyber Engine Tweaks overlay and "
                        + "press \"Reload all mods\" to load the new version.";
                }
                activity.Text = "Installed. You're ready to play.";
                Pop(mainButton);

                if (playAfter) Play();
            }
            catch (Exception ex)
            {
                SetBusy(false);
                Refresh();
                Fail(Friendly(ex));
            }
        }

        void Play()
        {
            if (game == null) return;
            if (Core.IsGameRunning())
            {
                activity.Text = "Cyberpunk 2077 is already running.";
                return;
            }
            try
            {
                Core.LaunchGame(game);
                activity.Text = "Starting Cyberpunk 2077...";
                mainButton.IsEnabled = false;
                var timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(8) };
                timer.Tick += delegate
                {
                    timer.Stop();
                    mainButton.IsEnabled = !busy;
                    activity.Text = "Have fun in Night City.";
                };
                timer.Start();
            }
            catch (Exception ex)
            {
                Fail("Couldn't start the game: " + ex.Message);
            }
        }

        void ChooseFolder()
        {
            if (busy) return;
            using (var dialog = new System.Windows.Forms.FolderBrowserDialog())
            {
                dialog.Description = "Choose the Cyberpunk 2077 folder (the one that contains \"bin\" and \"archive\").";
                dialog.ShowNewFolderButton = false;
                if (game != null) dialog.SelectedPath = game.Path;
                if (dialog.ShowDialog() != System.Windows.Forms.DialogResult.OK) return;

                string picked = dialog.SelectedPath;
                // Accept the game folder itself, or bin / bin\x64 inside it.
                for (int i = 0; i < 3 && picked != null && !Core.IsGameFolder(picked); i++)
                    picked = IOPath.GetDirectoryName(picked);

                if (!Core.IsGameFolder(picked))
                {
                    Fail("That folder doesn't contain Cyberpunk 2077 (no bin\\x64\\Cyberpunk2077.exe).");
                    return;
                }
                game = Core.Describe(picked);
                Core.RememberGameFolder(game.Path);
                Refresh();
            }
        }

        void Uninstall()
        {
            if (busy || game == null) return;
            if (Core.IsGameRunning())
            {
                Fail("Close Cyberpunk 2077 first, then uninstall.");
                return;
            }

            bool removeCet = false;
            if (Core.CetInstalled(game.Path) && !Core.HasOtherCetMods(game.Path))
            {
                MessageBoxResult choice = MessageBox.Show(window,
                    "Remove everything and go back to an unmodded game?\n\n"
                    + "Yes  -  remove the trainer and Cyber Engine Tweaks\n"
                    + "No  -  remove only the trainer\n\n"
                    + "Trainer settings and saved teleport spots are deleted. Your game saves are not touched.",
                    "Uninstall", MessageBoxButton.YesNoCancel, MessageBoxImage.Question);
                if (choice == MessageBoxResult.Cancel || choice == MessageBoxResult.None) return;
                removeCet = choice == MessageBoxResult.Yes;
            }
            else
            {
                MessageBoxResult answer = MessageBox.Show(window,
                    "Remove the Night City Trainer from this game?\n\n"
                    + "Trainer settings and saved teleport spots are deleted. Cyber Engine Tweaks "
                    + "stays because other mods use it. Your game saves are not touched.",
                    "Uninstall trainer", MessageBoxButton.OKCancel, MessageBoxImage.Question);
                if (answer != MessageBoxResult.OK) return;
            }
            try
            {
                Core.UninstallTrainer(game.Path);
                if (removeCet) Core.UninstallCet(game.Path);
                Refresh();
                activity.Text = removeCet ? "Trainer and Cyber Engine Tweaks removed." : "Trainer removed.";
            }
            catch (Exception ex)
            {
                Fail("Couldn't remove the trainer: " + Friendly(ex));
            }
        }

        void Fail(string message)
        {
            activity.Text = message;
            activity.Foreground = new SolidColorBrush(Color.FromRgb(0xFF, 0x6B, 0x7D));
            var timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(9) };
            timer.Tick += delegate
            {
                timer.Stop();
                activity.Foreground = new SolidColorBrush(Color.FromRgb(0xB9, 0xC4, 0xD6));
            };
            timer.Start();
            Log("ERROR " + message);
        }

        static string Friendly(Exception ex)
        {
            while (ex is AggregateException && ex.InnerException != null) ex = ex.InnerException;
            if (ex is WebException)
                return "Couldn't download. Check your internet connection and try again.";
            if (ex is UnauthorizedAccessException)
                return "Windows blocked writing to the game folder. Close the game, or run this launcher as administrator.";
            if (ex is IOException)
                return "A game file is in use. Close Cyberpunk 2077 and try again.";
            return ex.Message;
        }

        void Log(string line)
        {
            string file;
            if (!options.TryGetValue("log", out file)) return;
            try { File.AppendAllText(file, line + Environment.NewLine); } catch { }
        }

        // ---- Visuals ----------------------------------------------------------

        void Ui(Action action)
        {
            window.Dispatcher.BeginInvoke(action);
        }

        void SetDot(System.Windows.Shapes.Ellipse dot, Dot state)
        {
            Color color;
            switch (state)
            {
                case Dot.Ok: color = Color.FromRgb(0x3F, 0xFF, 0x99); break;
                case Dot.Warn: color = Color.FromRgb(0xFC, 0xEE, 0x0A); break;
                case Dot.Bad: color = Color.FromRgb(0xFF, 0x4C, 0x61); break;
                case Dot.Busy: color = Color.FromRgb(0x00, 0xF0, 0xFF); break;
                default: color = Color.FromRgb(0x55, 0x60, 0x7A); break;
            }
            dot.Fill = new SolidColorBrush(color);
            if (state == Dot.Busy)
            {
                var pulse = new DoubleAnimation(1, 0.25, TimeSpan.FromMilliseconds(550));
                pulse.AutoReverse = true;
                pulse.RepeatBehavior = RepeatBehavior.Forever;
                dot.BeginAnimation(UIElement.OpacityProperty, pulse);
            }
            else
            {
                dot.BeginAnimation(UIElement.OpacityProperty, null);
                dot.Opacity = 1;
            }
        }

        void SetProgress(double fraction, bool animate)
        {
            double width = Math.Max(0, Math.Min(1, fraction)) * progressTrack.ActualWidth;
            if (!animate)
            {
                progressFill.BeginAnimation(FrameworkElement.WidthProperty, null);
                progressFill.Width = width;
                return;
            }
            var grow = new DoubleAnimation(width, TimeSpan.FromMilliseconds(280));
            grow.EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut };
            progressFill.BeginAnimation(FrameworkElement.WidthProperty, grow);
        }

        static void Fade(UIElement element, double to, int milliseconds)
        {
            element.BeginAnimation(UIElement.OpacityProperty,
                new DoubleAnimation(to, TimeSpan.FromMilliseconds(milliseconds)));
        }

        // A quick "done" bounce.
        static void Pop(FrameworkElement element)
        {
            var scale = new ScaleTransform(1, 1);
            element.RenderTransformOrigin = new Point(0.5, 0.5);
            element.RenderTransform = scale;
            var bounce = new DoubleAnimation(1, 1.05, TimeSpan.FromMilliseconds(160));
            bounce.AutoReverse = true;
            bounce.EasingFunction = new QuadraticEase { EasingMode = EasingMode.EaseOut };
            scale.BeginAnimation(ScaleTransform.ScaleXProperty, bounce);
            scale.BeginAnimation(ScaleTransform.ScaleYProperty, bounce);
        }

        async Task SaveScreenshot(string file)
        {
            await Task.Delay(1600);
            var bitmap = new RenderTargetBitmap((int)window.ActualWidth, (int)window.ActualHeight,
                96, 96, PixelFormats.Pbgra32);
            bitmap.Render((Visual)window.Content);
            var encoder = new PngBitmapEncoder();
            encoder.Frames.Add(BitmapFrame.Create(bitmap));
            using (FileStream stream = File.Create(file)) encoder.Save(stream);
        }
    }

    public static class Program
    {
        [STAThread]
        public static void Main(string[] args)
        {
            // Developer switches used for testing: --game <folder> --install --shot <png>
            // --status <txt> --log <txt> --ignore-running --uninstall-all --exit
            var options = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            for (int i = 0; i < args.Length; i++)
            {
                if (!args[i].StartsWith("--")) continue;
                string key = args[i].Substring(2);
                bool hasValue = i + 1 < args.Length && !args[i + 1].StartsWith("--");
                options[key] = hasValue ? args[++i] : "";
            }

            var app = new Application();
            app.DispatcherUnhandledException += delegate(object s, DispatcherUnhandledExceptionEventArgs e)
            {
                MessageBox.Show("Something went wrong:\n\n" + e.Exception.Message, "Night City Trainer",
                    MessageBoxButton.OK, MessageBoxImage.Error);
                e.Handled = true;
            };
            try
            {
                app.Run(new LauncherWindow(options).Window);
            }
            catch (Exception ex)
            {
                string file;
                if (options.TryGetValue("log", out file)) File.AppendAllText(file, "FATAL " + ex + Environment.NewLine);
                else MessageBox.Show("The launcher could not start:\n\n" + ex.Message, "Night City Trainer");
            }
        }
    }
}
