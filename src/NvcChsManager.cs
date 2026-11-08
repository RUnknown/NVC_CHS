using System;
using System.Collections;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq.Expressions;
using System.Reflection;
using System.Text;
using System.Threading;

[assembly: AssemblyVersion("1.0.0.0")]

namespace NvcChs
{
    // Loaded as the default AppDomain's AppDomainManager, before Main and before
    // WPF assemblies exist. WPF is reached only by reflection from the UI dispatcher.
    // NvcChs.dll sits next to NVCleanstall.exe; data lives in the NVC_CHS subdir.
    public sealed class NvcChsManager : AppDomainManager
    {
        private const string SubDir = "NVC_CHS";
        // A UI change wakes a scan on the next tick; 100 ticks is the 1 s fallback.
        private const int WakeIntervalMs = 10;
        private const int FallbackTicks = 100;

        private static readonly object Sync = new object();
        private static readonly Dictionary<string, string> Dict =
            new Dictionary<string, string>(StringComparer.Ordinal);
        // "*prefix=value": the unmatched tail (speeds, counts) is kept verbatim.
        private static readonly List<KeyValuePair<string, string>> PrefixRules =
            new List<KeyValuePair<string, string>>();
        private static readonly HashSet<string> Seen = new HashSet<string>(StringComparer.Ordinal);
        private static readonly HashSet<string> Missing = new HashSet<string>(StringComparer.Ordinal);
        private static readonly HashSet<string> RecordedOnce = new HashSet<string>(StringComparer.Ordinal);
        // Getter per type; a null value means the type has no Inlines property.
        // Cached because both the metadata walk and the reflective get would
        // otherwise run per node and per scan.
        private static readonly Dictionary<Type, Func<object, object>> InlinesGetters =
            new Dictionary<Type, Func<object, object>>();
        private static readonly char[] NewLines = { '\n', '\r' };
        private static readonly UTF8Encoding Utf8NoBom = new UTF8Encoding(false);
        private static readonly Delegate ScanDelegate = new Action(ScanAll);

        // Release builds leave no files behind; build.ps1 -Diagnostics restores the
        // seen/missing/status dumps used to extend the dictionary.
#if DIAGNOSTICS
        private static readonly bool Diagnostics = true;
#else
        private static readonly bool Diagnostics = false;
#endif

        private static string _baseDir;
        private static string _dir;
        private static string _dictPath;
        private static DateTime _dictStamp;
        private static Timer _timer;
        private static int _pending;
        private static int _wake;
        private static int _dictCheck;
        private static int _ticks = FallbackTicks - 1;

        private static bool _subscribed;
        private static bool _initialised;
        private static bool _reflectionReady;
        private static bool _reflectionBroken;
        private static bool _layoutSubscribed;

        private static int _scans;
        private static int _hits;
        private static int _misses;
        private static int _replacements;
        private static int _errors;
        private static int _dirty;
        private static string _lastError = "";

        // Resolved once WPF is loaded, then reused on every scan. Delegates rather
        // than MethodInfo: Invoke allocates an argument array per call.
        private static Type _dependencyObjectType;
        private static Type _visualType;
        private static Type _frameworkElementType;
        private static Type _frameworkContentElementType;
        private static Func<object, object> _enumLocalValues;
        private static Action<object, object, object> _setValue;
        private static Func<object, int> _visualCount;
        private static Func<object, int, object> _visualChild;
        private static Func<object, object> _logicalChildren;
        private static Func<object, object> _getToolTip;
        private static Action<object, object> _setToolTip;
        private static Func<object, object> _entryProperty;
        private static Func<object, object> _entryValue;
        private static Func<object, string> _dpName;
        private static Func<object, object> _dpOwnerType;
        private static PropertyInfo _appCurrent;
        private static PropertyInfo _appWindows;
        private static PropertyInfo _elementDispatcher;
        private static MethodInfo _dispatcherBegin;

        public NvcChsManager()
        {
            // Subscribing must not depend on a path: BaseDirectory may be unpublished.
            try
            {
                if (!_subscribed)
                {
                    AppDomain.CurrentDomain.AssemblyLoad += OnAssemblyLoad;
                    _subscribed = true;
                }
            }
            catch (Exception e) { RecordOnce("CTOR_SUBSCRIBE_FAIL " + e.Message); }
            EnsureInitialised();
        }

        public override void InitializeNewDomain(AppDomainSetup appDomainInfo)
        {
            base.InitializeNewDomain(appDomainInfo);
            EnsureInitialised();
            EnsureTimer();
        }

        private static void EnsureInitialised()
        {
            if (_initialised) return;
            try
            {
                string baseDir = AppDomain.CurrentDomain.BaseDirectory;
                if (string.IsNullOrEmpty(baseDir)) return;

                _baseDir = baseDir;
                _dir = Path.Combine(baseDir, SubDir);
                _dictPath = ResolveDictPath();

                // A healthy run leaves no trace: the data subdir is created only when
                // there is something to report.
                if (Diagnostics)
                {
                    // Per-run truncation stops a long-lived install from growing a log forever.
                    if (!Directory.Exists(_dir)) Directory.CreateDirectory(_dir);
                    try { File.WriteAllText(Path.Combine(_dir, "error.log"), "", Utf8NoBom); }
                    catch { }
                }
                else CleanDataDir();

                LoadDictionary();
                _initialised = true;
            }
            catch (Exception e) { RecordOnce("INIT_FAIL " + e); }
        }

        // Files this patch may leave behind. The dictionary is user data and is kept.
        private static readonly string[] DataFiles = { "error.log", "status.txt", "seen.txt", "missing.txt" };

        // Release builds start from a clean slate: drop whatever a diagnostics build or an
        // earlier failure left, then the directory itself if nothing else uses it.
        private static void CleanDataDir()
        {
            if (string.IsNullOrEmpty(_dir)) return;
            try
            {
                foreach (string name in DataFiles)
                {
                    string f = Path.Combine(_dir, name);
                    if (File.Exists(f)) File.Delete(f);
                }
                if (Directory.Exists(_dir) && Directory.GetFileSystemEntries(_dir).Length == 0)
                    Directory.Delete(_dir);
            }
            catch { }
        }

        private static void OnAssemblyLoad(object sender, AssemblyLoadEventArgs args)
        {
            string name;
            try { name = args.LoadedAssembly.GetName().Name; } catch { return; }
            if (name == "PresentationFramework") EnsureTimer();
        }

        private static void EnsureTimer()
        {
            if (_timer != null) return;
            try { _timer = new Timer(Tick, null, 0, WakeIntervalMs); }
            catch (Exception e) { RecordOnce("TIMER_FAIL: " + e); }
        }

        // LayoutUpdated fires only when the layout really changed, so an idle UI
        // costs no scans. Only set a flag; Tick coalesces bursts.
        private static void OnUiChange(object sender, EventArgs e)
        {
            Interlocked.Exchange(ref _wake, 1);
        }

        // WPF broadcasts this event per Dispatcher, so one subscription covers
        // every window; subscribe from the UI thread during a scan.
        private static void SubscribeLayout(object window)
        {
            try
            {
                EventInfo ev = window.GetType().GetEvent(
                    "LayoutUpdated", BindingFlags.Public | BindingFlags.Instance);
                if (ev == null) RecordOnce("LAYOUT_EVENT_MISSING");
                else ev.AddEventHandler(window, new EventHandler(OnUiChange));
            }
            catch (Exception e) { RecordOnce("LAYOUT_SUBSCRIBE_FAIL " + e.Message); }
        }

        // At most one scan queued or running; BeginInvoke keeps the timer thread free.
        private static void Tick(object state)
        {
            if (!_initialised || _reflectionBroken) return;
            bool periodic = ++_ticks >= FallbackTicks;
            if (periodic)
            {
                _ticks = 0;
                Interlocked.Exchange(ref _dictCheck, 1);
            }
            // Retry every tick while WPF is still loading, so the layout event is
            // subscribed as soon as the UI exists. Compiling the accessors can fail
            // on a CLR that forbids dynamic code, and a throw here would kill the
            // process on the timer thread.
            if (!_reflectionReady)
            {
                bool ready;
                try { ready = EnsureReflection(); }
                catch (Exception e)
                {
                    _reflectionBroken = true;
                    RecordOnce("REFLECT_FAIL: " + e.Message);
                    return;
                }
                if (!ready) return;
            }
            // Claim the slot before clearing the flag: if a scan is already in
            // flight, the wake must survive for the next tick.
            if (Interlocked.CompareExchange(ref _pending, 1, 0) != 0) return;
            bool wake = Interlocked.Exchange(ref _wake, 0) != 0;
            if (!wake && !periodic)
            {
                Interlocked.Exchange(ref _pending, 0);
                return;
            }
            try
            {
                object app = _appCurrent.GetValue(null, null);
                if (app == null)
                {
                    Interlocked.Exchange(ref _pending, 0);
                    return;
                }
                object dispatcher = _elementDispatcher.GetValue(app, null);
                if (dispatcher == null)
                {
                    RecordOnce("DISPATCHER_NULL");
                    Interlocked.Exchange(ref _pending, 0);
                    return;
                }
                QueueScan(dispatcher);
            }
            catch (Exception e)
            {
                RecordOnce("TICK_FAIL: " + e);
                Interlocked.Exchange(ref _pending, 0);
            }
        }

        private static void QueueScan(object dispatcher)
        {
            if (_dispatcherBegin == null)
                _dispatcherBegin = dispatcher.GetType().GetMethod("BeginInvoke",
                    BindingFlags.Public | BindingFlags.Instance, null,
                    new Type[] { typeof(Delegate), typeof(object[]) }, null);

            if (_dispatcherBegin == null)
            {
                RecordOnce("NO_DISPATCHER_INVOKE");
                Interlocked.Exchange(ref _pending, 0);
                return;
            }
            _dispatcherBegin.Invoke(dispatcher, new object[] { ScanDelegate, new object[0] });
        }

        private static void ScanAll()
        {
            _scans++;
            // Reload on the UI thread: Translate reads Dict on this thread too.
            if (Interlocked.Exchange(ref _dictCheck, 0) != 0) EnsureDictionaryFresh();
            try
            {
                object app = _appCurrent.GetValue(null, null);
                if (app == null) return;
                IEnumerable e = _appWindows.GetValue(app, null) as IEnumerable;
                if (e == null) return;

                foreach (object window in e)
                {
                    if (window == null) continue;
                    if (!_layoutSubscribed)
                    {
                        SubscribeLayout(window);
                        _layoutSubscribed = true;
                    }
                    Walk(window, new HashSet<object>(), 0);
                }
            }
            catch (Exception ex) { RecordOnce("SCAN_FAIL: " + ex); }
            finally
            {
                Interlocked.Exchange(ref _pending, 0);
                if (_dirty != 0) Flush();
            }
        }

        private static bool EnsureReflection()
        {
            if (_reflectionReady) return true;
            Type doT = FindType("System.Windows.DependencyObject");
            _dependencyObjectType = doT;
            Type dpT = FindType("System.Windows.DependencyProperty");
            Type appT = FindType("System.Windows.Application");
            Type vhT = FindType("System.Windows.Media.VisualTreeHelper");
            if (doT == null || dpT == null || appT == null || vhT == null) return false;

            _enumLocalValues = CompileAccessor<Func<object, object>>(doT.GetMethod("GetLocalValueEnumerator",
                BindingFlags.Public | BindingFlags.Instance, null, Type.EmptyTypes, null));
            _setValue = CompileAccessor<Action<object, object, object>>(doT.GetMethod("SetValue",
                BindingFlags.Public | BindingFlags.Instance, null,
                new Type[] { dpT, typeof(object) }, null));
            _visualCount = CompileAccessor<Func<object, int>>(GetStaticMethod(vhT, "GetChildrenCount", 1));
            _visualChild = CompileAccessor<Func<object, int, object>>(GetStaticMethod(vhT, "GetChild", 2));
            _logicalChildren = CompileAccessor<Func<object, object>>(GetStaticMethod(
                FindType("System.Windows.LogicalTreeHelper"), "GetChildren", 1));
            _dpName = CompileGetter<Func<object, string>>(dpT, "Name");
            _dpOwnerType = CompileGetter<Func<object, object>>(dpT, "OwnerType");

            // Element kinds are checked before walking, so a Run or a data item does
            // not cost a thrown exception on every scan.
            _visualType = FindType("System.Windows.Media.Visual");
            _frameworkElementType = FindType("System.Windows.FrameworkElement");
            _frameworkContentElementType = FindType("System.Windows.FrameworkContentElement");

            Type ttT = FindType("System.Windows.Controls.ToolTipService");
            if (ttT != null)
            {
                _getToolTip = CompileAccessor<Func<object, object>>(ttT.GetMethod("GetToolTip",
                    BindingFlags.Public | BindingFlags.Static, null, new Type[] { doT }, null));
                _setToolTip = CompileAccessor<Action<object, object>>(ttT.GetMethod("SetToolTip",
                    BindingFlags.Public | BindingFlags.Static, null,
                    new Type[] { doT, typeof(object) }, null));
            }

            _appCurrent = appT.GetProperty("Current", BindingFlags.Public | BindingFlags.Static);
            _appWindows = appT.GetProperty("Windows", BindingFlags.Public | BindingFlags.Instance);
            Type dispatcherObject = FindType("System.Windows.Threading.DispatcherObject");
            if (dispatcherObject != null)
                _elementDispatcher = dispatcherObject.GetProperty(
                    "Dispatcher", BindingFlags.Public | BindingFlags.Instance);

            if (_enumLocalValues == null || _setValue == null || _visualCount == null ||
                _visualChild == null || _appCurrent == null || _appWindows == null ||
                _elementDispatcher == null) return false;

            _reflectionReady = true;
            return true;
        }

        private static void Walk(object node, HashSet<object> visited, int depth)
        {
            if (node == null || depth > 80 || !visited.Add(node)) return;
            try { TranslateObject(node); }
            catch (Exception e) { RecordOnce("NODE_FAIL: " + e.Message); }

            // Inlines (Run, Span) hold text but appear in neither tree. A text
            // element reports true here: its logical children are exactly those
            // inlines, so the logical walk below has nothing left to find.
            bool inlinesCovered = false;
            try { inlinesCovered = WalkInlines(node, visited, depth); }
            catch (Exception e) { RecordOnce("INLINES_FAIL: " + e.Message); }

            // GetChildrenCount throws for anything that is not a Visual, and one
            // thrown exception per node per scan costs more than the type test.
            int count = 0;
            if (_visualType == null || _visualType.IsInstanceOfType(node))
            {
                try { count = _visualCount(node); }
                catch { count = 0; }
            }
            for (int i = 0; i < count; i++)
            {
                object child;
                try { child = _visualChild(node, i); }
                catch { continue; }
                Walk(child, visited, depth + 1);
            }

            // Logical tree reaches collapsed, templated and popup content. It only
            // enumerates elements, so data items are skipped before the call.
            bool walkLogical = !inlinesCovered && _logicalChildren != null;
            if (walkLogical && _frameworkElementType != null && _frameworkContentElementType != null)
                walkLogical = _frameworkElementType.IsInstanceOfType(node) ||
                              _frameworkContentElementType.IsInstanceOfType(node);
            if (walkLogical)
            {
                try
                {
                    IEnumerable logical = _logicalChildren(node) as IEnumerable;
                    if (logical != null)
                        foreach (object child in logical)
                            Walk(child, visited, depth + 1);
                }
                catch (Exception e) { RecordOnce("LOGICAL_FAIL: " + e.Message); }
            }
        }

        // Returns true when this node's logical children are exactly its inlines,
        // which the caller may then skip.
        private static bool WalkInlines(object node, HashSet<object> visited, int depth)
        {
            if (depth > 80) return false;
            Type t = node.GetType();
            Func<object, object> get;
            if (!InlinesGetters.TryGetValue(t, out get))
            {
                PropertyInfo p = t.GetProperty("Inlines", BindingFlags.Public | BindingFlags.Instance);
                get = p == null ? null : CompileAccessor<Func<object, object>>(p.GetGetMethod());
                InlinesGetters[t] = get;
            }
            if (get == null) return false;

            IEnumerable inlines;
            try { inlines = get(node) as IEnumerable; } catch { return false; }
            if (inlines == null) return false;

            // Setting a Run's Text invalidates the InlineCollection enumerator, so
            // the nodes are collected first and translated afterwards. Its indexer
            // walks a linked list, so enumerating once is also the cheap way in.
            var items = new List<object>();
            foreach (object inline in inlines) items.Add(inline);
            foreach (object inline in items)
            {
                if (inline == null || !visited.Add(inline)) continue;
                try { TranslateObject(inline); } catch { }
                try { WalkInlines(inline, visited, depth + 1); } catch { }
            }
            return true;
        }

        private static void TranslateObject(object d)
        {
            // Logical trees hold plain objects too; a DependencyObject-bound
            // MethodInfo throws "Object does not match target type" on those.
            if (_dependencyObjectType == null || !_dependencyObjectType.IsInstanceOfType(d)) return;
            IEnumerator it = _enumLocalValues(d) as IEnumerator;
            if (it == null) return;

            // Setting a value while enumerating local values invalidates the enumerator.
            // Allocated only when something is actually replaced.
            List<KeyValuePair<object, string>> pending = null;
            while (true)
            {
                bool more;
                try { more = it.MoveNext(); } catch { break; }
                if (!more) break;
                object entry = it.Current;
                if (entry == null) continue;

                if (_entryProperty == null || _entryValue == null)
                {
                    Type et = entry.GetType();
                    _entryProperty = CompileGetter<Func<object, object>>(et, "Property");
                    _entryValue = CompileGetter<Func<object, object>>(et, "Value");
                }
                if (_entryProperty == null || _entryValue == null) return;

                object dp; object val;
                try
                {
                    dp = _entryProperty(entry);
                    val = _entryValue(entry);
                }
                catch { continue; }
                if (dp == null || !(val is string)) continue;

                string propName = null;
                try
                {
                    if (_dpName != null) propName = _dpName(dp);
                }
                catch { }

                // FrameworkElement.Name is a control id; AutomationProperties.Name
                // also reports "Name" but must stay visible to UIA.
                if (propName == "Name")
                {
                    Type owner = null;
                    try
                    {
                        if (_dpOwnerType != null) owner = _dpOwnerType(dp) as Type;
                    }
                    catch { }
                    if (owner != null && (owner.FullName == "System.Windows.FrameworkElement" ||
                        owner.FullName == "System.Windows.FrameworkContentElement")) continue;
                }

                string original = (string)val;
                // Chinese first: after the first pass most values are already
                // translated and this test exits on the first character.
                if (ContainsCjk(original) || !HasLatin(original)) continue;
                string translated = Translate(original);
                Observe(original, translated == original);
                if (translated != original)
                {
                    if (pending == null) pending = new List<KeyValuePair<object, string>>();
                    pending.Add(new KeyValuePair<object, string>(dp, translated));
                }
            }

            if (pending != null)
            {
                foreach (KeyValuePair<object, string> pair in pending)
                {
                    try
                    {
                        _setValue(d, pair.Key, pair.Value);
                        _replacements++;
                    }
                    catch (Exception e) { RecordOnce("SET_FAIL: " + e.Message); }
                }
            }

            // ToolTipService is an attached property, not a local value.
            try { TranslateToolTip(d); } catch { }
        }

        private static void TranslateToolTip(object d)
        {
            if (_getToolTip == null || _setToolTip == null) return;
            if (_dependencyObjectType == null || !_dependencyObjectType.IsInstanceOfType(d)) return;
            object tip = _getToolTip(d);
            string s = tip as string;
            if (s == null || ContainsCjk(s) || !HasLatin(s)) return;
            string translated = Translate(s);
            Observe(s, translated == s);
            if (translated != s)
            {
                _setToolTip(d, translated);
                _replacements++;
            }
        }

        private static string Translate(string s)
        {
            if (string.IsNullOrEmpty(s)) return s;
            string v;
            if (Dict.TryGetValue(s, out v)) { _hits++; return v; }

            // Live UI may use CRLF while the dictionary stores \n.
            if (s.IndexOfAny(NewLines) >= 0)
            {
                string normalised = s.Replace("\r\n", "\n").Replace("\r", "\n");
                if (Dict.TryGetValue(normalised, out v)) { _hits++; return v; }
            }

            // Padded values are common (two runs glued together), but Trim costs a
            // scan and up to two temporary strings, so only pay it for real padding.
            if (char.IsWhiteSpace(s[0]) || char.IsWhiteSpace(s[s.Length - 1]))
            {
                string trimmed = s.Trim();
                if (trimmed.Length > 0 && Dict.TryGetValue(trimmed, out v))
                {
                    _hits++;
                    int lead = 0;
                    while (char.IsWhiteSpace(s[lead])) lead++;
                    int tail = s.Length;
                    while (tail > lead && char.IsWhiteSpace(s[tail - 1])) tail--;
                    return s.Substring(0, lead) + v + s.Substring(tail);
                }
            }

            foreach (KeyValuePair<string, string> rule in PrefixRules)
            {
                if (s.StartsWith(rule.Key, StringComparison.Ordinal))
                {
                    _hits++;
                    return rule.Value + s.Substring(rule.Key.Length);
                }
            }
            _misses++;
            return s;
        }

        // Dynamic strings change on every scan; record the matched prefix instead
        // so seen.txt stays bounded.
        private static string NormaliseForObservation(string s)
        {
            foreach (KeyValuePair<string, string> rule in PrefixRules)
                if (s.StartsWith(rule.Key, StringComparison.Ordinal)) return rule.Key;
            return s;
        }

        private static void Observe(string s, bool pendingTranslation)
        {
            if (!Diagnostics || string.IsNullOrEmpty(s)) return;
            s = NormaliseForObservation(s);
            if (Seen.Add(s)) _dirty = 1;
            if (pendingTranslation)
            {
                if (Missing.Contains(s)) return;
                if (!ContainsCjk(s) && LooksLikeUiText(s) && Missing.Add(s)) _dirty = 1;
            }
            else
            {
                if (Missing.Remove(s)) _dirty = 1;
            }
        }

        private static bool ContainsCjk(string s)
        {
            foreach (char c in s)
                if (c >= '\u3400' && c <= '\u9fff') return true;
            return false;
        }

        private static int LatinCount(string s)
        {
            int n = 0;
            foreach (char c in s)
                if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z')) n++;
            return n;
        }

        private static bool LooksLikeUiText(string s)
        {
            if (s.Length < 2 || s.Length > 2000) return false;
            if (s.StartsWith("http", StringComparison.OrdinalIgnoreCase)) return false;
            if (s.StartsWith("HKEY", StringComparison.OrdinalIgnoreCase)) return false;
            if (s.StartsWith("pack://", StringComparison.OrdinalIgnoreCase)) return false;
            if (s.Length >= 3 && char.IsLetter(s[0]) && s[1] == ':' &&
                (s[2] == '\\' || s[2] == '/')) return false;
            return LatinCount(s) >= 2;
        }

        // Only the presence of a Latin letter matters on the hot path, so this stops
        // at the first one; LatinCount stays for the one caller that needs a count.
        private static bool HasLatin(string s)
        {
            foreach (char c in s)
                if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z')) return true;
            return false;
        }

        // A dictionary beside the exe wins; the data subdir is the fallback. Re-resolved
        // on every check so a file appearing at either location is picked up by hot reload.
        private static string ResolveDictPath()
        {
            if (string.IsNullOrEmpty(_baseDir)) return _dictPath;
            string beside = Path.Combine(_baseDir, "zh-CN.txt");
            if (File.Exists(beside)) return beside;
            return Path.Combine(_baseDir, SubDir, "zh-CN.txt");
        }

        private static string DictCandidates()
        {
            if (string.IsNullOrEmpty(_baseDir)) return _dictPath;
            return Path.Combine(_baseDir, "zh-CN.txt") + " or " + Path.Combine(_baseDir, SubDir, "zh-CN.txt");
        }

        private static void EnsureDictionaryFresh()
        {
            try
            {
                string path = ResolveDictPath();
                DateTime stamp = File.GetLastWriteTimeUtc(path);
                if (path == _dictPath && stamp == _dictStamp) return;
                _dictPath = path;
                // A failed reload keeps the old dictionary and the old stamp, so the
                // next tick retries instead of running untranslated for the session.
                if (!LoadDictionary()) return;
                Missing.Clear();
                _dirty = 1;
            }
            catch (Exception e) { RecordOnce("DICT_RELOAD_FAIL: " + e.Message); }
        }

        // One dictionary line can hold a multi-line WPF string; seen.txt and
        // missing.txt use the same escaping, so a line can be copied back as a key.
        private static string Unescape(string s)
        {
            var sb = new StringBuilder(s.Length);
            for (int i = 0; i < s.Length; i++)
            {
                if (s[i] != '\\' || i + 1 >= s.Length) { sb.Append(s[i]); continue; }
                char c = s[++i];
                switch (c)
                {
                    case 'n': sb.Append('\n'); break;
                    case 'r': sb.Append('\r'); break;
                    case 't': sb.Append('\t'); break;
                    case '\\': sb.Append('\\'); break;
                    default: sb.Append('\\').Append(c); break;
                }
            }
            return sb.ToString();
        }

        private static string Escape(string s)
        {
            return s.Replace("\\", "\\\\")
                    .Replace("\r\n", "\n")
                    .Replace("\r", "\n")
                    .Replace("\n", "\\n")
                    .Replace("\t", "\\t");
        }

        // Parses into fresh collections and swaps them in only after the whole file
        // was read: a half-read file must not replace a working dictionary.
        private static bool LoadDictionary()
        {
            var dict = new Dictionary<string, string>(StringComparer.Ordinal);
            var rules = new List<KeyValuePair<string, string>>();
            DateTime stamp = File.GetLastWriteTimeUtc(_dictPath);
            try
            {
                if (File.Exists(_dictPath))
                {
                    foreach (string line in File.ReadAllLines(_dictPath, Encoding.UTF8))
                    {
                        if (line.Length == 0) continue;
                        if (line[0] == '#' || line[0] == ';') continue;
                        int eq = line.IndexOf('=');
                        if (eq <= 0) continue;
                        string key = Unescape(line.Substring(0, eq));
                        string val = Unescape(line.Substring(eq + 1));
                        if (key.Length == 0) continue;

                        if (key[0] == '*' && key.Length > 1)
                            rules.Add(new KeyValuePair<string, string>(key.Substring(1), val));
                        else
                            dict[key] = val;
                    }
                }
                // Still succeed: the file can be dropped in later, and the stamp
                // check in EnsureDictionaryFresh reloads it without a restart.
                else RecordOnce("DICT_MISSING: " + DictCandidates());
            }
            catch (Exception e) { RecordOnce("DICT_FAIL: " + e); return false; }

            // Longest prefix wins over generic rules.
            rules.Sort((a, b) => b.Key.Length.CompareTo(a.Key.Length));
            Dict.Clear();
            foreach (KeyValuePair<string, string> kv in dict) Dict.Add(kv.Key, kv.Value);
            PrefixRules.Clear();
            PrefixRules.AddRange(rules);
            _dictStamp = stamp;
            return true;
        }

        private static void Flush()
        {
            lock (Sync)
            {
                if (!Diagnostics)
                {
                    _dirty = 0;
                    return;
                }
                try
                {
                    File.WriteAllLines(Path.Combine(_dir, "seen.txt"),
                        SortedEscaped(Seen), Utf8NoBom);
                    File.WriteAllLines(Path.Combine(_dir, "missing.txt"),
                        SortedEscaped(Missing), Utf8NoBom);
                    File.WriteAllText(Path.Combine(_dir, "status.txt"),
                        "dictionary=" + Dict.Count + "\r\n" +
                        "dictionaryPath=" + _dictPath + "\r\n" +
                        "prefixRules=" + PrefixRules.Count + "\r\n" +
                        "scans=" + _scans + "\r\n" +
                        "wakeIntervalMs=" + WakeIntervalMs + "\r\n" +
                        "fallbackMs=" + (FallbackTicks * WakeIntervalMs) + "\r\n" +
                        "seen=" + Seen.Count + "\r\n" +
                        "missing=" + Missing.Count + "\r\n" +
                        "hits=" + _hits + "\r\n" +
                        "misses=" + _misses + "\r\n" +
                        "replacements=" + _replacements + "\r\n" +
                        "errors=" + _errors + "\r\n" +
                        "lastError=" + _lastError + "\r\n",
                        Utf8NoBom);
                    _dirty = 0;
                }
                catch { }
            }
        }

        private static string[] SortedEscaped(HashSet<string> set)
        {
            string[] a = new string[set.Count];
            set.CopyTo(a);
            for (int i = 0; i < a.Length; i++) a[i] = Escape(a[i]);
            Array.Sort(a, StringComparer.Ordinal);
            return a;
        }

        private static void RecordOnce(string message)
        {
            lock (Sync)
            {
                if (!RecordedOnce.Add(message)) return;
                _errors++;
                _dirty = 1;
                _lastError = message;
                if (string.IsNullOrEmpty(_dir)) return;
                try
                {
                    // A failure is the one thing allowed to create the data subdir.
                    if (!Directory.Exists(_dir)) Directory.CreateDirectory(_dir);
                    File.AppendAllText(Path.Combine(_dir, "error.log"),
                        DateTime.Now.ToString("o", CultureInfo.InvariantCulture) + " " + message + "\r\n",
                        Utf8NoBom);
                }
                catch { }
            }
        }

        private static Type FindType(string fullName)
        {
            foreach (Assembly a in AppDomain.CurrentDomain.GetAssemblies())
            {
                Type t;
                try { t = a.GetType(fullName, false); } catch { continue; }
                if (t != null) return t;
            }
            return null;
        }

        private static MethodInfo GetStaticMethod(Type t, string name, int argCount)
        {
            if (t == null) return null;
            foreach (MethodInfo m in t.GetMethods(BindingFlags.Public | BindingFlags.Static))
                if (m.Name == name && m.GetParameters().Length == argCount) return m;
            return null;
        }

        // MethodInfo.Invoke allocates an argument array and re-checks it on every
        // call; a compiled expression calls the same member directly. Public
        // members with fixed signatures only, which is all that is bound here.
        private static T CompileAccessor<T>(MethodInfo m) where T : class
        {
            if (m == null) return null;
            MethodInfo invoke = typeof(T).GetMethod("Invoke");
            ParameterInfo[] dp = invoke.GetParameters();
            ParameterInfo[] mp = m.GetParameters();
            int first = m.IsStatic ? 0 : 1;

            var args = new ParameterExpression[dp.Length];
            for (int i = 0; i < dp.Length; i++)
                args[i] = Expression.Parameter(dp[i].ParameterType, "a" + i);

            var callArgs = new Expression[mp.Length];
            for (int i = 0; i < mp.Length; i++)
                callArgs[i] = Expression.Convert(args[i + first], mp[i].ParameterType);
            Expression target = m.IsStatic ? null : Expression.Convert(args[0], m.DeclaringType);
            Expression call = Expression.Call(target, m, callArgs);

            Type ret = invoke.ReturnType;
            Expression body = ret == typeof(void) ? call : Expression.Convert(call, ret);
            return (T)(object)Expression.Lambda(typeof(T), body, args).Compile();
        }

        private static T CompileGetter<T>(Type t, string name) where T : class
        {
            PropertyInfo p = t.GetProperty(name, BindingFlags.Public | BindingFlags.Instance);
            return p == null ? null : CompileAccessor<T>(p.GetGetMethod());
        }
    }
}
