import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';
import 'package:webview_flutter/webview_flutter.dart';

// ───────────────────────── Download model & manager ─────────────────────────

class Dl {
  String id, url, name, path, status; // downloading | paused | done | error
  int total, received;
  CancelToken? token;
  Dl({
    required this.id,
    required this.url,
    required this.name,
    required this.path,
    this.status = 'paused',
    this.total = 0,
    this.received = 0,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'url': url,
        'name': name,
        'path': path,
        'status': status,
        'total': total,
        'received': received,
      };

  factory Dl.fromJson(Map<String, dynamic> j) => Dl(
        id: j['id'],
        url: j['url'],
        name: j['name'],
        path: j['path'],
        status: j['status'],
        total: j['total'] ?? 0,
        received: j['received'] ?? 0,
      );

  double? get progress => total > 0 ? (received / total).clamp(0.0, 1.0) : null;
}

String fmtBytes(int b) {
  if (b < 1024) return '$b B';
  if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
  if (b < 1024 * 1024 * 1024) return '${(b / 1024 / 1024).toStringAsFixed(1)} MB';
  return '${(b / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
}

class Manager extends ChangeNotifier {
  Manager._();
  static final Manager i = Manager._();

  final items = <Dl>[];
  int maxConc = 2; // simultaneous downloads
  final _dio = Dio();
  late Directory dir;
  late File _index;

  Future<void> init() async {
    final base =
        await getExternalStorageDirectory() ?? await getApplicationDocumentsDirectory();
    dir = Directory('${base.path}/Downloads');
    await dir.create(recursive: true);
    _index = File('${dir.path}/.index.json');
    if (await _index.exists()) {
      try {
        final list = jsonDecode(await _index.readAsString()) as List;
        for (final e in list) {
          final d = Dl.fromJson(Map<String, dynamic>.from(e));
          if (d.status == 'downloading' || d.status == 'queued') d.status = 'paused';
          items.add(d);
        }
      } catch (_) {}
    }
    notifyListeners();
  }

  bool _svc = false;
  DateTime _lastNotif = DateTime(2000);

  // Keeps the process alive (foreground service) and shows progress notification.
  Future<void> _sync({bool force = false}) async {
    final act = items
        .where((e) => e.status == 'downloading' || e.status == 'queued')
        .toList();
    final running = act.where((e) => e.status == 'downloading').toList();
    try {
      if (act.isEmpty) {
        if (_svc) {
          _svc = false;
          await FlutterForegroundTask.stopService();
        }
        return;
      }
      final recv = running.fold<int>(0, (a, e) => a + e.received);
      final tot = running.fold<int>(0, (a, e) => a + e.total);
      final queued = act.length - running.length;
      final text = '${running.length} downloading' +
          (queued > 0 ? ' • $queued queued' : '') +
          ' • ' +
          (tot > 0 ? '${(recv * 100 / tot).floor()}%' : fmtBytes(recv));
      if (!_svc) {
        _svc = true;
        _lastNotif = DateTime.now();
        await FlutterForegroundTask.startService(
          serviceId: 256,
          notificationTitle: 'Video Downloader',
          notificationText: text,
        );
      } else if (force || DateTime.now().difference(_lastNotif).inMilliseconds > 1000) {
        _lastNotif = DateTime.now();
        await FlutterForegroundTask.updateService(
          notificationTitle: 'Video Downloader',
          notificationText: text,
        );
      }
    } catch (_) {}
  }

  Future<void> _save() async {
    await _index.writeAsString(jsonEncode(items.map((e) => e.toJson()).toList()));
  }

  String _nameFromUrl(String url, [String prefix = '']) {
    var n = '';
    try {
      final segs = Uri.parse(url).pathSegments.where((s) => s.isNotEmpty);
      if (segs.isNotEmpty) n = Uri.decodeComponent(segs.last);
    } catch (_) {}
    n = n.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    if (n.isEmpty) n = 'video_${DateTime.now().millisecondsSinceEpoch}';
    if (!n.contains('.')) n = '$n.mp4';
    n = '$prefix$n';
    var out = n, k = 1;
    while (File('${dir.path}/$out').existsSync() || items.any((e) => e.name == out)) {
      final dot = n.lastIndexOf('.');
      out = '${n.substring(0, dot)}($k)${n.substring(dot)}';
      k++;
    }
    return out;
  }

  Future<void> add(String url) => _addOne(url, '');

  // Adds many links; they run in this order (limited by maxConc at a time).
  Future<void> addBatch(List<String> urls, {bool numbered = true}) async {
    final digits = urls.length.toString().length;
    final w = digits < 2 ? 2 : digits;
    for (var i = 0; i < urls.length; i++) {
      final prefix = numbered ? '${(i + 1).toString().padLeft(w, '0')} - ' : '';
      await _addOne(urls[i], prefix);
    }
  }

  Future<void> _addOne(String url, String prefix) async {
    final name = _nameFromUrl(url, prefix);
    final d = Dl(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      url: url,
      name: name,
      path: '${dir.path}/$name',
      status: 'queued',
    );
    items.add(d); // keep list order = queue order
    await _save();
    notifyListeners();
    _pump();
  }

  // Starts queued items (top of the list first) while there are free slots.
  void _pump() {
    final running = items.where((e) => e.status == 'downloading').length;
    var slots = maxConc - running;
    for (final d in items.toList()) {
      if (slots <= 0) break;
      if (d.status == 'queued') {
        slots--;
        unawaited(_run(d));
      }
    }
  }

  void setMax(int n) {
    maxConc = n;
    notifyListeners();
    _pump();
  }

  void resume(Dl d) {
    if (d.status == 'downloading' || d.status == 'queued') return;
    d.status = 'queued';
    notifyListeners();
    _pump();
    unawaited(_sync(force: true));
  }

  void pause(Dl d) {
    if (d.status == 'queued') {
      d.status = 'paused';
      notifyListeners();
      unawaited(_save());
      unawaited(_sync(force: true));
    } else {
      d.token?.cancel('pause');
    }
  }

  Future<void> remove(Dl d) async {
    d.token?.cancel('remove');
    items.remove(d);
    try {
      final f = File(d.path);
      if (await f.exists()) await f.delete();
    } catch (_) {}
    await _save();
    notifyListeners();
  }

  Future<void> _run(Dl d) async {
    if (d.status == 'downloading') return;
    d.status = 'downloading';
    d.token = CancelToken();
    notifyListeners();
    unawaited(_sync(force: true));

    final file = File(d.path);
    int start = await file.exists() ? await file.length() : 0;
    IOSink? sink;
    var lastUi = DateTime.now();
    try {
      final resp = await _dio.get<ResponseBody>(
        d.url,
        cancelToken: d.token,
        options: Options(
          responseType: ResponseType.stream,
          followRedirects: true,
          headers: start > 0 ? {'range': 'bytes=$start-'} : null,
        ),
      );
      if (resp.statusCode == 200) start = 0; // server ignored Range
      final len = int.tryParse(resp.headers.value('content-length') ?? '') ?? 0;
      d.total = len > 0 ? len + start : 0;
      d.received = start;
      sink = file.openWrite(mode: start > 0 ? FileMode.append : FileMode.write);
      await for (final chunk in resp.data!.stream) {
        sink.add(chunk);
        d.received += chunk.length;
        if (DateTime.now().difference(lastUi).inMilliseconds > 250) {
          lastUi = DateTime.now();
          notifyListeners();
          unawaited(_sync());
        }
      }
      await sink.flush();
      await sink.close();
      sink = null;
      d.status = 'done';
      d.total = d.received;
    } on DioException catch (e) {
      try {
        await sink?.close();
      } catch (_) {}
      if (CancelToken.isCancel(e)) {
        d.status = 'paused';
      } else if (e.response?.statusCode == 416) {
        d.status = 'done';
      } else {
        d.status = 'error';
      }
    } catch (_) {
      try {
        await sink?.close();
      } catch (_) {}
      d.status = 'error';
    }
    await _save();
    notifyListeners();
    _pump();
    unawaited(_sync(force: true));
  }
}

// ───────────────────────── App ─────────────────────────

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'downloads',
        channelName: 'Downloads',
        channelDescription: 'Download progress',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
      ),
      iosNotificationOptions: const IOSNotificationOptions(showNotification: false),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        autoRunOnBoot: false,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
  } catch (_) {}
  await Manager.i.init();
  runApp(const App());
}

class App extends StatelessWidget {
  const App({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Video Downloader',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          colorSchemeSeed: Colors.red,
          brightness: Brightness.dark,
        ),
        home: const Home(),
      );
}

class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  int tab = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        await FlutterForegroundTask.requestNotificationPermission();
      } catch (_) {}
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: IndexedStack(
            index: tab,
            children: const [BrowserTab(), DownloadsTab()],
          ),
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: tab,
          onDestinationSelected: (i) => setState(() => tab = i),
          destinations: const [
            NavigationDestination(icon: Icon(Icons.public), label: 'Browser'),
            NavigationDestination(icon: Icon(Icons.download), label: 'Downloads'),
          ],
        ),
      );
}

// ───────────────────────── Browser tab ─────────────────────────

const _mediaExt = [
  '.mp4', '.mkv', '.webm', '.mov', '.avi', '.3gp', '.m4v',
  '.mp3', '.m4a', '.aac', '.ogg', '.wav', '.flac',
];

bool _isMediaUrl(String u) {
  try {
    final p = Uri.parse(u).path.toLowerCase();
    return _mediaExt.any(p.endsWith);
  } catch (_) {
    return false;
  }
}

class BrowserTab extends StatefulWidget {
  const BrowserTab({super.key});
  @override
  State<BrowserTab> createState() => _BrowserTabState();
}

class _BrowserTabState extends State<BrowserTab> {
  late final WebViewController c;
  final urlCtl = TextEditingController(text: 'https://www.google.com');

  @override
  void initState() {
    super.initState();
    c = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(NavigationDelegate(
        onNavigationRequest: (req) {
          if (_isMediaUrl(req.url)) {
            _download(req.url);
            return NavigationDecision.prevent;
          }
          return NavigationDecision.navigate;
        },
        onPageStarted: (u) => setState(() => urlCtl.text = u),
      ))
      ..loadRequest(Uri.parse('https://www.google.com'));
  }

  void _toast(String m) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(m)));
  }

  Future<void> _download(String url) async {
    await Manager.i.add(url);
    _toast('Added to Downloads');
  }

  void _go(String text) {
    var t = text.trim();
    if (t.isEmpty) return;
    if (!t.startsWith('http')) {
      t = (t.contains('.') && !t.contains(' '))
          ? 'https://$t'
          : 'https://www.google.com/search?q=${Uri.encodeQueryComponent(t)}';
    }
    c.loadRequest(Uri.parse(t));
  }

  Future<void> _detect() async {
    try {
      final r = await c.runJavaScriptReturningResult(
        "Array.from(document.querySelectorAll('video,source,audio')).map(e=>e.currentSrc||e.src)"
        ".filter(s=>s&&s.startsWith('http')).join('\\n')",
      );
      var s = r.toString();
      if (s.startsWith('"')) s = jsonDecode(s) as String;
      final links = s.split('\n').where((e) => e.trim().isNotEmpty).toSet().toList();
      if (links.isEmpty) {
        _toast('No direct video found on this page');
        return;
      }
      if (!mounted) return;
      showModalBottomSheet(
        context: context,
        builder: (_) => ListView(
          children: [
            for (final l in links)
              ListTile(
                leading: const Icon(Icons.movie),
                title: Text(l, maxLines: 2, overflow: TextOverflow.ellipsis),
                trailing: const Icon(Icons.download),
                onTap: () {
                  Navigator.pop(context);
                  _download(l);
                },
              ),
          ],
        ),
      );
    } catch (_) {
      _toast('Could not scan this page');
    }
  }

  @override
  Widget build(BuildContext context) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
            child: Row(
              children: [
                IconButton(
                    icon: const Icon(Icons.arrow_back),
                    onPressed: () async {
                      if (await c.canGoBack()) c.goBack();
                    }),
                Expanded(
                  child: TextField(
                    controller: urlCtl,
                    keyboardType: TextInputType.url,
                    textInputAction: TextInputAction.go,
                    onSubmitted: _go,
                    decoration: const InputDecoration(
                      isDense: true,
                      border: OutlineInputBorder(),
                      hintText: 'Search or type URL',
                    ),
                  ),
                ),
                IconButton(icon: const Icon(Icons.refresh), onPressed: c.reload),
                IconButton(
                  icon: const Icon(Icons.download_for_offline),
                  tooltip: 'Find videos on this page',
                  onPressed: _detect,
                ),
              ],
            ),
          ),
          Expanded(child: WebViewWidget(controller: c)),
        ],
      );
}

// ───────────────────────── Downloads tab ─────────────────────────

class DownloadsTab extends StatefulWidget {
  const DownloadsTab({super.key});
  @override
  State<DownloadsTab> createState() => _DownloadsTabState();
}

class _DownloadsTabState extends State<DownloadsTab> {
  @override
  void initState() {
    super.initState();
    Manager.i.addListener(_r);
  }

  @override
  void dispose() {
    Manager.i.removeListener(_r);
    super.dispose();
  }

  void _r() {
    if (mounted) setState(() {});
  }

  Future<void> _paste() async {
    final ctl = TextEditingController();
    final url = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Paste direct link'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(hintText: 'https://.../video.mp4'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, ctl.text.trim()),
              child: const Text('Download')),
        ],
      ),
    );
    if (url != null && url.startsWith('http')) await Manager.i.add(url);
  }

  Future<void> _batch() async {
    final ctl = TextEditingController();
    var numbered = true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: const Text('Paste links (one per line)'),
          content: SizedBox(
            width: double.maxFinite,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: ctl,
                  autofocus: true,
                  minLines: 5,
                  maxLines: 8,
                  keyboardType: TextInputType.multiline,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    hintText: 'https://.../1.mp4\nhttps://.../2.mp4',
                  ),
                ),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: numbered,
                  onChanged: (v) => setS(() => numbered = v ?? true),
                  title: const Text('Number files (01 - ...)'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Add to queue')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    final links = <String>[];
    for (final l in ctl.text.split('\n')) {
      final t = l.trim();
      if (t.startsWith('http') && !links.contains(t)) links.add(t);
    }
    if (links.isNotEmpty) await Manager.i.addBatch(links, numbered: numbered);
  }

  @override
  Widget build(BuildContext context) {
    final items = Manager.i.items;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Downloads'),
        actions: [
          PopupMenuButton<int>(
            icon: const Icon(Icons.tune),
            tooltip: 'Simultaneous downloads',
            onSelected: Manager.i.setMax,
            itemBuilder: (_) => [
              for (final n in [1, 2, 3])
                CheckedPopupMenuItem<int>(
                  value: n,
                  checked: Manager.i.maxConc == n,
                  child: Text('$n at a time'),
                ),
            ],
          ),
        ],
      ),
      floatingActionButton: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          FloatingActionButton.small(
            heroTag: 'batch',
            onPressed: _batch,
            child: const Icon(Icons.playlist_add),
          ),
          const SizedBox(height: 12),
          FloatingActionButton(
            heroTag: 'single',
            onPressed: _paste,
            child: const Icon(Icons.add_link),
          ),
        ],
      ),
      body: items.isEmpty
          ? const Center(child: Text('No downloads yet'))
          : ListView.builder(
              itemCount: items.length,
              itemBuilder: (_, i) => _tile(items[i]),
            ),
    );
  }

  Widget _tile(Dl d) {
    final sizeTxt = d.total > 0
        ? '${fmtBytes(d.received)} / ${fmtBytes(d.total)}'
        : fmtBytes(d.received);
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(d.name, maxLines: 2, overflow: TextOverflow.ellipsis),
            const SizedBox(height: 8),
            if (d.status != 'done')
              LinearProgressIndicator(
                value: d.status == 'downloading' && d.progress == null
                    ? null
                    : (d.progress ?? 0.0),
              ),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(child: Text('${d.status} • $sizeTxt')),
                if (d.status == 'downloading' || d.status == 'queued')
                  IconButton(
                      icon: const Icon(Icons.pause), onPressed: () => Manager.i.pause(d)),
                if (d.status == 'paused' || d.status == 'error')
                  IconButton(
                      icon: const Icon(Icons.play_arrow),
                      onPressed: () => Manager.i.resume(d)),
                if (d.status == 'done')
                  IconButton(
                    icon: const Icon(Icons.play_circle),
                    onPressed: () => Navigator.push(
                        context, MaterialPageRoute(builder: (_) => PlayerPage(d: d))),
                  ),
                IconButton(
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => Manager.i.remove(d)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ───────────────────────── Player ─────────────────────────

class PlayerPage extends StatefulWidget {
  final Dl d;
  const PlayerPage({super.key, required this.d});
  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  late final VideoPlayerController vc;
  bool ready = false;

  @override
  void initState() {
    super.initState();
    vc = VideoPlayerController.file(File(widget.d.path))
      ..initialize().then((_) {
        if (!mounted) return;
        setState(() => ready = true);
        vc.play();
      });
  }

  @override
  void dispose() {
    vc.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(widget.d.name, overflow: TextOverflow.ellipsis)),
        body: !ready
            ? const Center(child: CircularProgressIndicator())
            : Column(
                children: [
                  Expanded(
                    child: Center(
                      child: AspectRatio(
                        aspectRatio: vc.value.aspectRatio == 0 ? 16 / 9 : vc.value.aspectRatio,
                        child: VideoPlayer(vc),
                      ),
                    ),
                  ),
                  VideoProgressIndicator(vc, allowScrubbing: true),
                  IconButton(
                    iconSize: 48,
                    icon: Icon(vc.value.isPlaying ? Icons.pause : Icons.play_arrow),
                    onPressed: () => setState(
                        () => vc.value.isPlaying ? vc.pause() : vc.play()),
                  ),
                  const SizedBox(height: 16),
                ],
              ),
      );
}
