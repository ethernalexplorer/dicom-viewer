import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const DicomViewerApp());
}

class DicomViewerApp extends StatelessWidget {
  const DicomViewerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'DICOM Viewer',
      theme: ThemeData(
        fontFamily: 'Segoe UI',
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF2F9BFF)),
        useMaterial3: true,
      ),
      home: const DicomViewerScreen(),
    );
  }
}

class DicomViewerScreen extends StatefulWidget {
  const DicomViewerScreen({super.key});

  @override
  State<DicomViewerScreen> createState() => _DicomViewerScreenState();
}

class _DicomViewerScreenState extends State<DicomViewerScreen> {
  final List<DicomSeries> _series = [];
  DicomSeries? _selectedSeries;
  DicomFileInfo? _selectedFile;
  DicomImageData? _currentImage;
  ui.Image? _renderedImage;
  final Map<String, DicomImageData> _imageCache = {};
  int _loadSerial = 0;
  String _patientName = '—';
  String? _message;
  bool _isLoading = true;
  DateTime _loadingStartedAt = DateTime.now();
  double _brightness = 0;
  double _contrast = 100;
  double _zoom = 1;
  Offset _pan = Offset.zero;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => unawaited(_startAutoDiscovery()),
    );
  }

  Future<void> _startAutoDiscovery() async {
    // Не начинаем обход диска в callback первого кадра: синхронная работа в этот
    // момент не давала Windows показать уже собранный Flutter-кадр с плашкой.
    await WidgetsBinding.instance.endOfFrame;
    _loadingStartedAt = DateTime.now();
    await Future<void>.delayed(const Duration(milliseconds: 700));
    if (!mounted) return;
    await _scanDefaultArchive();
  }

  Future<void> _scanDefaultArchive() async {
    // Directory.current при запуске двойным щелчком может указывать, например,
    // на «Документы», а не на каталог приложения. Поэтому основная точка поиска
    // всегда определяется по фактическому пути запущенного DicomViewer.exe.
    final executableDirectory = File(Platform.resolvedExecutable).parent;
    final current = Directory.current;
    final candidates = <Directory>[
      executableDirectory,
      executableDirectory.parent,
      current,
      current.parent,
    ];

    final uniqueCandidates = <Directory>[];
    final knownPaths = <String>{};
    for (final candidate in candidates) {
      final normalizedPath = candidate.absolute.path.toLowerCase();
      if (knownPaths.add(normalizedPath)) uniqueCandidates.add(candidate);
    }

    Directory? archive;
    // Сначала проверяем DICOM непосредственно рядом с EXE (или в другом
    // корневом кандидате), а уже потом вложенные каталоги.
    for (final root in uniqueCandidates) {
      if (await _hasDicomFilesDirectly(root)) {
        archive = root;
        break;
      }
    }

    for (final root in uniqueCandidates) {
      if (archive != null) break;
      try {
        await for (final entity in root.list()) {
          if (entity is! Directory) continue;
          if (await _hasDicomFiles(entity)) {
            archive = entity;
            break;
          }
        }
      } catch (_) {
        // Недоступные системные каталоги не должны останавливать автопоиск.
      }
      if (archive != null) break;
    }
    await _scanArchive(archive ?? executableDirectory);
  }

  Future<bool> _hasDicomFilesDirectly(Directory dir) async {
    try {
      await for (final entity in dir.list()) {
        if (entity is File && _isDicomFile(entity)) return true;
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _hasDicomFiles(Directory dir) async {
    try {
      await for (final entity in dir.list(recursive: true)) {
        if (entity is File && _isDicomFile(entity)) {
          return true;
        }
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  bool _isDicomFile(File file) {
    try {
      if (file.path.toLowerCase().endsWith('.dcm')) return true;
      final handle = file.openSync();
      if (handle.lengthSync() < 132) {
        handle.closeSync();
        return false;
      }
      handle.setPositionSync(128);
      final magic = handle.readSync(4);
      handle.closeSync();
      return String.fromCharCodes(magic) == 'DICM';
    } catch (_) {
      return false;
    }
  }

  Future<void> _scanArchive(Directory root) async {
    _loadingStartedAt = DateTime.now();
    setState(() {
      _series.clear();
      _selectedSeries = null;
      _selectedFile = null;
      _currentImage = null;
      _renderedImage?.dispose();
      _renderedImage = null;
      _message = null;
      _isLoading = true;
    });

    // Даём Flutter отрисовать индикатор до синхронного чтения файлов.
    await Future<void>.delayed(const Duration(milliseconds: 60));

    final files = <DicomFileInfo>[];
    try {
      await for (final entity in root.list(recursive: true)) {
        if (entity is! File) continue;
        final file = entity;
        if (!_isDicomFile(file)) continue;
        try {
          final header = DicomParser.readHeader(file.path);
          if (header != null) files.add(header);
        } catch (_) {
          // DICOMDIR and unsupported service objects are not image slices.
        }
      }
    } catch (e) {
      await _waitForLoadingBadge();
      setState(() {
        _message = 'Не удалось прочитать исследование';
        _isLoading = false;
      });
      return;
    }

    files.sort((a, b) {
      final s = (a.seriesNumber ?? 0).compareTo(b.seriesNumber ?? 0);
      if (s != 0) return s;
      return (a.instanceNumber ?? 0).compareTo(b.instanceNumber ?? 0);
    });

    final groups = <String, List<DicomFileInfo>>{};
    for (final file in files) {
      final key =
          file.seriesUid ??
          'series-${file.seriesNumber}-${file.seriesDescription}';
      groups.putIfAbsent(key, () => []).add(file);
    }

    final parsedSeries = groups.entries.map((e) {
      e.value.sort(
        (a, b) => (a.instanceNumber ?? 0).compareTo(b.instanceNumber ?? 0),
      );
      return DicomSeries(e.key, e.value);
    }).toList();

    setState(() {
      _series
        ..clear()
        ..addAll(parsedSeries);
      _patientName = files.isEmpty
          ? '—'
          : Transliteration.toRussianName(
              files
                  .firstWhere((f) => (f.patientName ?? '').isNotEmpty)
                  .patientName,
            );
      _message = files.isEmpty
          ? 'DICOM-исследование рядом с приложением не найдено'
          : 'Загрузка исследования...';
    });

    if (_series.isNotEmpty) {
      await _selectSeries(_series.first);
    }
    await _waitForLoadingBadge();
    if (mounted) setState(() => _isLoading = false);
  }

  Future<void> _waitForLoadingBadge() async {
    const minimumVisibleTime = Duration(milliseconds: 900);
    final elapsed = DateTime.now().difference(_loadingStartedAt);
    if (elapsed < minimumVisibleTime) {
      await Future<void>.delayed(minimumVisibleTime - elapsed);
    }
  }

  Future<void> _selectSeries(DicomSeries series) async {
    setState(() => _selectedSeries = series);
    if (series.files.isNotEmpty) await _loadImage(series.files.first);
  }

  Future<void> _loadImage(DicomFileInfo file) async {
    final serial = ++_loadSerial;
    try {
      final image = _imageCache[file.path] ??= DicomParser.readImage(file.path);
      final rendered = await image.toUiImage(brightness: 0, contrast: 100);
      if (!mounted || serial != _loadSerial) return;
      setState(() {
        _selectedFile = file;
        _currentImage = image;
        _renderedImage = rendered;
        _brightness = 0;
        _contrast = 100;
        _zoom = 1;
        _pan = Offset.zero;
        _message = null;
      });
    } catch (e) {
      if (!mounted || serial != _loadSerial) return;
      setState(() {
        _currentImage = null;
        _renderedImage = null;
        _message = 'Не удалось открыть снимок: $e';
      });
    }
  }

  Future<void> _renderWindow() async {
    final image = _currentImage;
    if (image == null) return;
    final rendered = await image.toUiImage(
      brightness: _brightness,
      contrast: _contrast,
    );
    if (mounted) setState(() => _renderedImage = rendered);
  }

  Future<void> _moveImage(int delta) async {
    final series = _selectedSeries;
    final file = _selectedFile;
    if (series == null || file == null) return;
    final currentIndex = series.files.indexOf(file);
    final next = (currentIndex + delta).clamp(0, series.files.length - 1);
    await _loadImage(series.files[next]);
  }

  Future<void> _resetView() async {
    setState(() {
      _brightness = 0;
      _contrast = 100;
      _zoom = 1;
      _pan = Offset.zero;
    });
    await _renderWindow();
  }

  void _zoomAtPointer(Offset pointer, Size viewport, double factor) {
    final oldZoom = _zoom;
    final newZoom = (oldZoom * factor).clamp(1.0, 16.0);
    if (newZoom == oldZoom) return;

    final viewportCenter = Offset(viewport.width / 2, viewport.height / 2);
    final pointerFromImageCenter = pointer - viewportCenter - _pan;
    final newPan =
        pointer - viewportCenter - pointerFromImageCenter * (newZoom / oldZoom);

    setState(() {
      _zoom = newZoom;
      _pan = newZoom == 1 ? Offset.zero : newPan;
    });
  }

  @override
  void dispose() {
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFFF7FBFF), Color(0xFFEDF6FF), Color(0xFFF4F8FC)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: Stack(
          children: [
            const _LiquidBackground(),
            Padding(
              padding: const EdgeInsets.fromLTRB(32, 24, 32, 28),
              child: Column(
                children: [
                  _HeaderCard(patientName: _patientName),
                  const SizedBox(height: 22),
                  Expanded(
                    child: Row(
                      children: [
                        _SeriesPanel(
                          series: _series,
                          selected: _selectedSeries,
                          onSelect: _selectSeries,
                        ),
                        const SizedBox(width: 20),
                        Expanded(child: _viewerPanel()),
                        const SizedBox(width: 20),
                        _PatientHelpPanel(onShowAbout: _showAboutDialog),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            if (_isLoading)
              const Positioned.fill(
                child: ColoredBox(
                  color: Color(0x260B1726),
                  child: Center(child: _LoadingBadge()),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _viewerPanel() {
    return Container(
      decoration: _cardDecoration(
        color: Colors.black,
        radius: 20,
        shadow: true,
      ),
      clipBehavior: Clip.antiAlias,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final viewport = Size(constraints.maxWidth, constraints.maxHeight);
          return Listener(
            onPointerSignal: (event) {
              if (event is PointerScrollEvent) {
                if (HardwareKeyboard.instance.isControlPressed) {
                  _zoomAtPointer(
                    event.localPosition,
                    viewport,
                    event.scrollDelta.dy < 0 ? 1.15 : 1 / 1.15,
                  );
                } else {
                  unawaited(_moveImage(event.scrollDelta.dy > 0 ? 1 : -1));
                }
              }
            },
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanUpdate: (details) {
                if (_zoom > 1) setState(() => _pan += details.delta);
              },
              child: Stack(
                alignment: Alignment.center,
                children: [
                  if (_renderedImage != null)
                    Positioned.fill(
                      child: RepaintBoundary(
                        child: CustomPaint(
                          painter: _DicomImagePainter(
                            image: _renderedImage!,
                            zoom: _zoom,
                            pan: _pan,
                          ),
                        ),
                      ),
                    ),
                  if (_currentImage != null && _selectedFile != null)
                    Positioned.fill(
                      child: IgnorePointer(
                        child: _DicomOverlay(
                          image: _currentImage!,
                          file: _selectedFile!,
                          series: _selectedSeries,
                          zoom: _zoom,
                          brightness: _brightness,
                          contrast: _contrast,
                        ),
                      ),
                    ),
                  if (_currentImage != null)
                    Positioned(
                      right: 14,
                      bottom: 14,
                      child: _ViewerControls(
                        brightness: _brightness,
                        contrast: _contrast,
                        onBrightnessChanged: (value) {
                          setState(() => _brightness = value);
                          unawaited(_renderWindow());
                        },
                        onContrastChanged: (value) {
                          setState(() => _contrast = value);
                          unawaited(_renderWindow());
                        },
                        onReset: _resetView,
                      ),
                    ),
                  if (_message != null)
                    Container(
                      padding: const EdgeInsets.all(28),
                      decoration: BoxDecoration(
                        color: const Color(0xDD0D1B2F),
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(color: const Color(0x3335A8FF)),
                      ),
                      child: Text(
                        _message!,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _showAboutDialog() async {
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.info_outline_rounded, color: Color(0xFF278FD8)),
            SizedBox(width: 10),
            Text('О программе'),
          ],
        ),
        content: const SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'DICOM Viewer 1.0.0',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
                ),
                SizedBox(height: 14),
                Text(
                  'Программа предназначена исключительно для просмотра DICOM-изображений в ознакомительных целях. Она не выполняет диагностику, не формирует медицинское заключение и не заменяет консультацию квалифицированного врача.',
                  style: TextStyle(height: 1.4),
                ),
                SizedBox(height: 12),
                Text(
                  'Результаты исследования, диагноз и рекомендации следует получать у лечащего врача или медицинской организации. Не принимайте медицинские решения только на основании изображения в этой программе.',
                  style: TextStyle(height: 1.4),
                ),
                SizedBox(height: 16),
                Divider(),
                SizedBox(height: 12),
                Text(
                  'Лицензирование и компоненты',
                  style: TextStyle(fontWeight: FontWeight.w800),
                ),
                SizedBox(height: 6),
                Text(
                  'Программная часть распространяется на условиях лицензии MIT. Приложение создано с использованием Flutter и сторонних компонентов с открытым исходным кодом. Тексты лицензий и уведомления находятся в комплекте поставки в файлах LICENSE.txt и THIRD_PARTY_NOTICES.txt.',
                  style: TextStyle(height: 1.4),
                ),
                SizedBox(height: 12),
                Text(
                  'Наименования, логотипы и товарные знаки сторонних организаций не входят в состав программы и не предоставляются по лицензии MIT.',
                  style: TextStyle(height: 1.4),
                ),
                SizedBox(height: 12),
                Text(
                  'Программа предоставляется «как есть», без каких-либо явно выраженных или подразумеваемых гарантий, в пределах, допускаемых применимым законодательством.',
                  style: TextStyle(height: 1.4, color: Color(0xFF65758B)),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Закрыть'),
          ),
        ],
      ),
    );
  }
}

class _LoadingBadge extends StatelessWidget {
  const _LoadingBadge();

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
    decoration: BoxDecoration(
      color: const Color(0xE6111D2D),
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: const Color(0x6635A8FF)),
      boxShadow: const [
        BoxShadow(
          color: Color(0x77000000),
          blurRadius: 14,
          offset: Offset(0, 4),
        ),
      ],
    ),
    child: const Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(
            strokeWidth: 2.4,
            color: Color(0xFF35A8FF),
          ),
        ),
        SizedBox(width: 10),
        Text(
          'Загрузка исследования…',
          style: TextStyle(
            color: Colors.white,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    ),
  );
}

class _PatientHelpPanel extends StatelessWidget {
  const _PatientHelpPanel({required this.onShowAbout});

  final VoidCallback onShowAbout;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 270,
    child: Container(
      padding: const EdgeInsets.all(18),
      decoration: _cardDecoration(radius: 20, shadow: true),
      child: Column(
        children: [
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: const [
                  Row(
                    children: [
                      Icon(
                        Icons.help_outline_rounded,
                        color: Color(0xFF35A8FF),
                        size: 22,
                      ),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text('Как пользоваться', style: _titleStyle),
                      ),
                    ],
                  ),
                  SizedBox(height: 18),
                  _HelpItem(
                    icon: Icons.mouse_rounded,
                    title: 'Листать снимки',
                    text:
                        'Прокручивайте колесо мыши для перехода между снимками.',
                  ),
                  _HelpItem(
                    icon: Icons.zoom_in_rounded,
                    title: 'Увеличить',
                    text:
                        'Удерживайте Ctrl и вращайте колесо мыши. Масштабирование выполняется относительно курсора.',
                  ),
                  _HelpItem(
                    icon: Icons.pan_tool_alt_rounded,
                    title: 'Переместить',
                    text:
                        'На увеличенном снимке удерживайте левую кнопку мыши и перемещайте изображение.',
                  ),
                  _HelpItem(
                    icon: Icons.tune_rounded,
                    title: 'Настроить изображение',
                    text:
                        'Используйте ползунки яркости и контраста в правом нижнем углу снимка.',
                  ),
                  SizedBox(height: 8),
                  Divider(color: Color(0xFFDCE8F4)),
                  SizedBox(height: 8),
                  Text(
                    'Просмотрщик предназначен для ознакомления со снимками. Медицинское заключение и интерпретацию результатов предоставляет врач.',
                    style: TextStyle(
                      color: Color(0xFF65758B),
                      fontSize: 12,
                      height: 1.35,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const Divider(color: Color(0xFFDCE8F4)),
          const SizedBox(height: 4),
          SizedBox(
            width: double.infinity,
            child: TextButton.icon(
              onPressed: onShowAbout,
              icon: const Icon(Icons.info_outline_rounded, size: 18),
              label: const Text('О программе'),
            ),
          ),
        ],
      ),
    ),
  );
}

class _HelpItem extends StatelessWidget {
  const _HelpItem({
    required this.icon,
    required this.title,
    required this.text,
  });
  final IconData icon;
  final String title;
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: const Color(0xFFE3F2FF),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, color: const Color(0xFF278FD8), size: 18),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  color: Color(0xFF172033),
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                text,
                style: const TextStyle(
                  color: Color(0xFF65758B),
                  fontSize: 12,
                  height: 1.3,
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _ViewerControls extends StatelessWidget {
  const _ViewerControls({
    required this.brightness,
    required this.contrast,
    required this.onBrightnessChanged,
    required this.onContrastChanged,
    required this.onReset,
  });
  final double brightness;
  final double contrast;
  final ValueChanged<double> onBrightnessChanged;
  final ValueChanged<double> onContrastChanged;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) => Container(
    width: 250,
    padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
    decoration: BoxDecoration(
      color: const Color(0xD90D1724),
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: const Color(0x5535A8FF)),
      boxShadow: const [BoxShadow(color: Color(0x66000000), blurRadius: 12)],
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _CompactSlider(
          label: 'Яркость',
          value: brightness,
          min: -100,
          max: 100,
          display: '${brightness.round()}%',
          onChanged: onBrightnessChanged,
        ),
        _CompactSlider(
          label: 'Контраст',
          value: contrast,
          min: 1,
          max: 200,
          display: '${contrast.round()}%',
          onChanged: onContrastChanged,
        ),
        SizedBox(
          width: double.infinity,
          height: 28,
          child: FilledButton(
            onPressed: onReset,
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF35A8FF),
              padding: EdgeInsets.zero,
            ),
            child: const Text(
              'Сбросить',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
            ),
          ),
        ),
      ],
    ),
  );
}

class _CompactSlider extends StatelessWidget {
  const _CompactSlider({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.display,
    required this.onChanged,
  });
  final String label;
  final double value;
  final double min;
  final double max;
  final String display;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: const TextStyle(color: Colors.white, fontSize: 12),
          ),
          Text(
            display,
            style: const TextStyle(color: Color(0xFF8DD0FF), fontSize: 12),
          ),
        ],
      ),
      SizedBox(
        height: 24,
        child: SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 2,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 10),
          ),
          child: Slider(value: value, min: min, max: max, onChanged: onChanged),
        ),
      ),
    ],
  );
}

class _DicomImagePainter extends CustomPainter {
  const _DicomImagePainter({
    required this.image,
    required this.zoom,
    required this.pan,
  });

  final ui.Image image;
  final double zoom;
  final Offset pan;

  @override
  void paint(Canvas canvas, Size size) {
    final imageSize = Size(image.width.toDouble(), image.height.toDouble());
    final fitScale = math.min(
      size.width / imageSize.width,
      size.height / imageSize.height,
    );
    final destinationSize = Size(
      imageSize.width * fitScale * zoom,
      imageSize.height * fitScale * zoom,
    );
    final center = Offset(size.width / 2, size.height / 2) + pan;
    final destination = Rect.fromCenter(
      center: center,
      width: destinationSize.width,
      height: destinationSize.height,
    );
    final source = Rect.fromLTWH(0, 0, imageSize.width, imageSize.height);
    final paint = Paint()
      ..filterQuality = FilterQuality.high
      ..isAntiAlias = true;

    canvas.drawImageRect(image, source, destination, paint);
  }

  @override
  bool shouldRepaint(covariant _DicomImagePainter oldDelegate) {
    return oldDelegate.image != image ||
        oldDelegate.zoom != zoom ||
        oldDelegate.pan != pan;
  }
}

class _DicomOverlay extends StatelessWidget {
  const _DicomOverlay({
    required this.image,
    required this.file,
    required this.series,
    required this.zoom,
    required this.brightness,
    required this.contrast,
  });

  final DicomImageData image;
  final DicomFileInfo file;
  final DicomSeries? series;
  final double zoom;
  final double brightness;
  final double contrast;

  String get _patientName => Transliteration.toRussianName(file.patientName);
  String get _instanceText {
    final total =
        image.overlayTags['ImagesInAcquisition'] ??
        '${series?.files.length ?? 1}';
    return '${file.instanceNumber ?? 1}/$total';
  }

  @override
  Widget build(BuildContext context) {
    final effectiveCenter =
        image.windowCenter - brightness * image.windowWidth / 100.0;
    final effectiveWidth = math.max(
      1,
      image.windowWidth * 100.0 / math.max(1, contrast),
    );
    final tags = image.overlayTags;
    final matrix = tags['AcquisitionMatrix'];
    final orientation = _orientationLabels(tags['ImageOrientationPatient']);
    final topLeft = [
      _joinPresent([
        tags['MagneticFieldStrength'] == null
            ? null
            : '${_trimNumber(tags['MagneticFieldStrength']!)}T',
        file.modality,
        tags['StationName'],
      ]),
      if (tags['StudyID'] != null) 'Ex: ${tags['StudyID']}',
      _joinPresent([
        tags['ScanningSequence'],
        tags['SequenceVariant'],
        tags['MRAcquisitionType'],
      ]),
      if (tags['ProtocolName'] != null) tags['ProtocolName']!,
      if (file.seriesDescription != null) file.seriesDescription!,
      'Se: ${file.seriesNumber ?? '—'}/${tags['NumberOfStudyRelatedSeries'] ?? '—'}',
      'Im: $_instanceText',
      if (tags['SliceLocation'] != null)
        '${image.planeLabel}: ${_trimNumber(tags['SliceLocation']!)}',
      'Mag: ${zoom.toStringAsFixed(1)}×',
    ].where((line) => line.isNotEmpty).toList();
    final topRight = [
      if (tags['InstitutionName'] != null) tags['InstitutionName']!,
      if (_patientName.isNotEmpty) _patientName,
      _patientDemographics(tags),
      if ((file.patientId ?? '').isNotEmpty) 'ID: ${file.patientId}',
      if (tags['AccessionNumber'] != null) 'Acc: ${tags['AccessionNumber']}',
      if ((image.studyDate ?? '').isNotEmpty)
        _formatDicomDate(image.studyDate!),
      if ((image.studyTime ?? '').isNotEmpty)
        'Acq Tm: ${_formatDicomTime(image.studyTime!)}',
      matrix == null
          ? '${image.width} × ${image.height}'
          : matrix.replaceAll('/', ' × '),
    ].where((line) => line.isNotEmpty).toList();
    final bottomLeft = [
      if (tags['EchoTrainLength'] != null) 'ETL: ${tags['EchoTrainLength']}',
      if ((image.repetitionTime ?? '').isNotEmpty)
        'TR: ${_formatDecimal(image.repetitionTime!)}',
      if ((image.echoTime ?? '').isNotEmpty)
        'TE: ${_formatDecimal(image.echoTime!)}',
      if (tags['NumberOfAverages'] != null) 'NEX: ${tags['NumberOfAverages']}',
      if (tags['ReceiveCoilName'] != null) tags['ReceiveCoilName']!,
      if ((image.sliceThickness ?? '').isNotEmpty)
        '${_trimNumber(image.sliceThickness!)}thk/${tags['SpacingBetweenSlices'] == null ? '—' : _trimNumber(tags['SpacingBetweenSlices']!)}sp',
      'W: ${effectiveWidth.round()}  L: ${effectiveCenter.round()}',
    ];
    final bottomRight = [
      if (tags['FlipAngle'] != null) 'FA: ${_trimNumber(tags['FlipAngle']!)}°',
      if (tags['PatientPosition'] != null) tags['PatientPosition']!,
      if ((image.fieldOfView ?? '').isNotEmpty) 'DFOV: ${image.fieldOfView}',
    ];

    return Padding(
      padding: const EdgeInsets.all(14),
      child: Stack(
        children: [
          Align(
            alignment: Alignment.topLeft,
            child: _OverlayText(lines: topLeft),
          ),
          Align(
            alignment: Alignment.topRight,
            child: _OverlayText(lines: topRight, textAlign: TextAlign.right),
          ),
          Align(
            alignment: Alignment.bottomLeft,
            child: _OverlayText(lines: bottomLeft),
          ),
          Align(
            alignment: Alignment.bottomRight,
            child: _OverlayText(lines: bottomRight, textAlign: TextAlign.right),
          ),
          Align(
            alignment: Alignment.topCenter,
            child: _OrientationLabel(orientation.top),
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: _OrientationLabel(orientation.bottom),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: _OrientationLabel(orientation.left),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: _OrientationLabel(orientation.right),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: Padding(
              padding: const EdgeInsets.only(right: 24),
              child: _ImageScale(height: 180),
            ),
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 24),
              child: _HorizontalScale(width: 230),
            ),
          ),
        ],
      ),
    );
  }
}

String _joinPresent(List<String?> values) => values
    .whereType<String>()
    .where((value) => value.trim().isNotEmpty)
    .join(' ');

String _patientDemographics(Map<String, String> tags) {
  final birth = tags['PatientBirthDate'];
  final sex = tags['PatientSex'];
  final age = tags['PatientAge'];
  return _joinPresent([
    birth == null ? null : _formatDicomDate(birth),
    sex,
    age,
  ]);
}

String _trimNumber(String value) {
  final number = double.tryParse(value);
  if (number == null) return value;
  return number == number.roundToDouble()
      ? number.round().toString()
      : number.toString();
}

String _formatDecimal(String value) {
  final number = double.tryParse(value);
  if (number == null) return value;
  return number.toStringAsFixed(number.abs() < 10 ? 1 : 0);
}

({String top, String bottom, String left, String right}) _orientationLabels(
  String? raw,
) {
  if (raw == null) return (top: 'A', bottom: 'P', left: 'R', right: 'L');
  final values = raw
      .split('/')
      .map(double.tryParse)
      .whereType<double>()
      .toList();
  if (values.length < 6) return (top: 'A', bottom: 'P', left: 'R', right: 'L');
  String direction(double x, double y, double z) {
    final absolute = [x.abs(), y.abs(), z.abs()];
    final maxValue = absolute.reduce(math.max);
    if (maxValue == x.abs()) return x >= 0 ? 'L' : 'R';
    if (maxValue == y.abs()) return y >= 0 ? 'P' : 'A';
    return z >= 0 ? 'H' : 'F';
  }

  final right = direction(values[0], values[1], values[2]);
  final bottom = direction(values[3], values[4], values[5]);
  const opposite = {'L': 'R', 'R': 'L', 'A': 'P', 'P': 'A', 'H': 'F', 'F': 'H'};
  return (
    top: opposite[bottom]!,
    bottom: bottom,
    left: opposite[right]!,
    right: right,
  );
}

class _ImageScale extends StatelessWidget {
  const _ImageScale({required this.height});
  final double height;

  @override
  Widget build(BuildContext context) => CustomPaint(
    size: Size(22, height),
    painter: const _ScalePainter(vertical: true),
  );
}

class _HorizontalScale extends StatelessWidget {
  const _HorizontalScale({required this.width});
  final double width;

  @override
  Widget build(BuildContext context) => CustomPaint(
    size: Size(width, 18),
    painter: const _ScalePainter(vertical: false),
  );
}

class _ScalePainter extends CustomPainter {
  const _ScalePainter({required this.vertical});
  final bool vertical;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white
      ..strokeWidth = 1;
    final length = vertical ? size.height : size.width;
    final cross = vertical ? size.width : size.height;
    for (var i = 0; i <= 10; i++) {
      final position = length * i / 10;
      final tick = i == 0 || i == 5 || i == 10
          ? cross
          : (i.isEven ? cross * .65 : cross * .42);
      if (vertical) {
        canvas.drawLine(
          Offset(cross - tick, position),
          Offset(cross, position),
          paint,
        );
      } else {
        canvas.drawLine(
          Offset(position, cross - tick),
          Offset(position, cross),
          paint,
        );
      }
    }
    if (vertical) {
      canvas.drawLine(Offset(cross, 0), Offset(cross, length), paint);
    } else {
      canvas.drawLine(Offset(0, cross), Offset(length, cross), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _ScalePainter oldDelegate) => false;
}

class _OverlayText extends StatelessWidget {
  const _OverlayText({required this.lines, this.textAlign = TextAlign.left});
  final List<String> lines;
  final TextAlign textAlign;

  @override
  Widget build(BuildContext context) => Text(
    lines.join('\n'),
    textAlign: textAlign,
    style: const TextStyle(
      color: Color(0xFFF4F8FF),
      fontFamily: 'Segoe UI',
      fontSize: 13,
      height: 1.25,
      fontWeight: FontWeight.w500,
      shadows: [
        Shadow(color: Colors.black, blurRadius: 3),
        Shadow(color: Colors.black, offset: Offset(1, 1)),
      ],
    ),
  );
}

class _OrientationLabel extends StatelessWidget {
  const _OrientationLabel(this.label);
  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(4),
    child: Text(
      label,
      style: const TextStyle(
        color: Colors.white,
        fontSize: 16,
        fontWeight: FontWeight.w700,
        shadows: [Shadow(color: Colors.black, blurRadius: 4)],
      ),
    ),
  );
}

String _formatDicomDate(String value) {
  final digits = value.replaceAll(RegExp(r'[^0-9]'), '');
  if (digits.length < 8) return value;
  return '${digits.substring(6, 8)}.${digits.substring(4, 6)}.${digits.substring(0, 4)}';
}

String _formatDicomTime(String value) {
  final digits = value.replaceAll(RegExp(r'[^0-9]'), '');
  if (digits.length < 4) return value;
  final seconds = digits.length >= 6 ? ':${digits.substring(4, 6)}' : '';
  return '${digits.substring(0, 2)}:${digits.substring(2, 4)}$seconds';
}

class _HeaderCard extends StatelessWidget {
  const _HeaderCard({required this.patientName});
  final String patientName;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 132,
      padding: const EdgeInsets.symmetric(horizontal: 26),
      decoration: _cardDecoration(
        radius: 24,
        shadow: true,
        gradient: const LinearGradient(
          colors: [Color(0xFFF2F8FF), Color(0xFFDCEBFB), Color(0xFFF8FCFF)],
        ),
      ),
      child: Stack(
        children: [
          const Positioned.fill(child: _HeaderLines()),
          Row(
            children: [
              Container(
                width: 58,
                height: 58,
                decoration: BoxDecoration(
                  color: const Color(0xFFE3F2FF),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: const Icon(
                  Icons.medical_information_outlined,
                  color: Color(0xFF278FD8),
                  size: 32,
                ),
              ),
              const SizedBox(width: 18),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      patientName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 30,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF172033),
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'DICOM архив исследования',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFFB0084F),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SeriesPanel extends StatelessWidget {
  const _SeriesPanel({
    required this.series,
    required this.selected,
    required this.onSelect,
  });
  final List<DicomSeries> series;
  final DicomSeries? selected;
  final ValueChanged<DicomSeries> onSelect;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 310,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: _cardDecoration(radius: 20, shadow: true),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Серии', style: _titleStyle),
            const SizedBox(height: 12),
            Expanded(
              child: ListView.builder(
                itemCount: series.length,
                itemBuilder: (context, index) {
                  final item = series[index];
                  final isSelected = identical(item, selected);
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(14),
                      onTap: () => onSelect(item),
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: isSelected
                              ? const Color(0xFFDCEBFB)
                              : const Color(0xFFEEF6FF),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: const Color(0xFFDCE8F4)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              item.displayTitle,
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                                color: Color(0xFF172033),
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              item.displaySubtitle,
                              style: const TextStyle(color: Color(0xFF65758B)),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LiquidBackground extends StatelessWidget {
  const _LiquidBackground();
  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}

class _HeaderLines extends StatelessWidget {
  const _HeaderLines();
  @override
  Widget build(BuildContext context) =>
      CustomPaint(painter: _HeaderLinesPainter());
}

class _HeaderLinesPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final p1 = Paint()
      ..color = const Color(0x4435A8FF)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4;
    final p2 = Paint()
      ..color = const Color(0x3300C7A7)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    canvas.drawPath(
      Path()
        ..moveTo(20, 82)
        ..cubicTo(260, 12, 436, 126, 696, 44)
        ..cubicTo(860, -8, 1080, 86, size.width - 70, 26),
      p1,
    );
    canvas.drawPath(
      Path()
        ..moveTo(18, 36)
        ..cubicTo(230, 106, 448, -12, 684, 72)
        ..cubicTo(870, 120, 1030, 18, size.width - 40, 90),
      p2,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

BoxDecoration _cardDecoration({
  double radius = 20,
  bool shadow = false,
  Color color = const Color(0xFFF8FCFF),
  Gradient? gradient,
}) {
  return BoxDecoration(
    color: gradient == null ? color : null,
    gradient: gradient,
    borderRadius: BorderRadius.circular(radius),
    border: Border.all(color: const Color(0xFFDCE8F4)),
    boxShadow: shadow
        ? const [
            BoxShadow(
              color: Color(0x249EB8D6),
              blurRadius: 14,
              offset: Offset(0, 4),
            ),
          ]
        : null,
  );
}

const _titleStyle = TextStyle(
  fontSize: 18,
  fontWeight: FontWeight.w800,
  color: Color(0xFF172033),
);

class DicomSeries {
  DicomSeries(this.uid, this.files);
  final String uid;
  final List<DicomFileInfo> files;
  String get displayTitle =>
      '${files.first.seriesNumber ?? '—'}. ${files.first.seriesDescription ?? 'Без описания'}';
  String get displaySubtitle =>
      '${files.first.modality ?? 'MR'} · ${files.length} снимков';
}

class DicomFileInfo {
  DicomFileInfo({
    required this.path,
    required this.fileName,
    this.studyUid,
    this.seriesUid,
    this.patientName,
    this.patientId,
    this.studyDescription,
    this.seriesDescription,
    this.modality,
    this.seriesNumber,
    this.instanceNumber,
    this.rows,
    this.columns,
  });
  final String path;
  final String fileName;
  final String? studyUid;
  final String? seriesUid;
  final String? patientName;
  final String? patientId;
  final String? studyDescription;
  final String? seriesDescription;
  final String? modality;
  final int? seriesNumber;
  final int? instanceNumber;
  final int? rows;
  final int? columns;
}

class DicomImageData {
  DicomImageData({
    required this.width,
    required this.height,
    required this.pixels,
    required this.min,
    required this.max,
    required this.windowCenter,
    required this.windowWidth,
    required this.invert,
    required this.metadataText,
    required this.overlayTags,
    this.studyDate,
    this.studyTime,
    this.repetitionTime,
    this.echoTime,
    this.sliceThickness,
    this.pixelSpacing,
    this.fieldOfView,
  });
  final int width;
  final int height;
  final Int32List pixels;
  final int min;
  final int max;
  final double windowCenter;
  final double windowWidth;
  final bool invert;
  final String metadataText;
  final Map<String, String> overlayTags;
  final String? studyDate;
  final String? studyTime;
  final String? repetitionTime;
  final String? echoTime;
  final String? sliceThickness;
  final String? pixelSpacing;
  final String? fieldOfView;

  String get planeLabel {
    final raw = overlayTags['ImageOrientationPatient'];
    if (raw == null) return 'Loc';
    final v = raw.split('/').map(double.tryParse).whereType<double>().toList();
    if (v.length < 6) return 'Loc';
    final nx = v[1] * v[5] - v[2] * v[4];
    final ny = v[2] * v[3] - v[0] * v[5];
    final nz = v[0] * v[4] - v[1] * v[3];
    if (nx.abs() >= ny.abs() && nx.abs() >= nz.abs()) return 'Sag';
    if (ny.abs() >= nz.abs()) return 'Cor';
    return 'Ax';
  }

  Future<ui.Image> toUiImage({
    required double brightness,
    required double contrast,
  }) {
    final center = windowCenter - brightness * windowWidth / 100.0;
    final widthValue = math.max(1, windowWidth * 100.0 / math.max(1, contrast));
    final low = center - widthValue / 2;
    final high = center + widthValue / 2;
    final rgba = Uint8List(width * height * 4);
    for (var i = 0; i < pixels.length; i++) {
      var gray = (((pixels[i] - low) / (high - low)) * 255).round().clamp(
        0,
        255,
      );
      if (invert) gray = 255 - gray;
      final o = i * 4;
      rgba[o] = gray;
      rgba[o + 1] = gray;
      rgba[o + 2] = gray;
      rgba[o + 3] = 255;
    }
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      rgba,
      width,
      height,
      ui.PixelFormat.rgba8888,
      completer.complete,
    );
    return completer.future;
  }
}

class DicomParser {
  static const _longVr = {
    'OB',
    'OD',
    'OF',
    'OL',
    'OV',
    'OW',
    'SQ',
    'UC',
    'UR',
    'UT',
    'UN',
  };

  static DicomFileInfo? readHeader(String path) {
    final bytes = File(path).readAsBytesSync();
    if (!_hasPreamble(bytes)) return null;
    final elements = _readElements(bytes, stopAtPixelData: true);
    final rows = _getInt(bytes, elements, 0x0028, 0x0010);
    final columns = _getInt(bytes, elements, 0x0028, 0x0011);
    if (rows == null || columns == null) return null;
    return DicomFileInfo(
      path: path,
      fileName: path.split(Platform.pathSeparator).last,
      studyUid: _getString(bytes, elements, 0x0020, 0x000D),
      seriesUid: _getString(bytes, elements, 0x0020, 0x000E),
      patientName: _getString(bytes, elements, 0x0010, 0x0010),
      patientId: _getString(bytes, elements, 0x0010, 0x0020),
      studyDescription: _getString(bytes, elements, 0x0008, 0x1030),
      seriesDescription: _getString(bytes, elements, 0x0008, 0x103E),
      modality: _getString(bytes, elements, 0x0008, 0x0060),
      seriesNumber: _getInt(bytes, elements, 0x0020, 0x0011),
      instanceNumber: _getInt(bytes, elements, 0x0020, 0x0013),
      rows: rows,
      columns: columns,
    );
  }

  static DicomImageData readImage(String path) {
    final bytes = File(path).readAsBytesSync();
    if (!_hasPreamble(bytes)) {
      throw const FormatException('нет DICOM-преамбулы');
    }
    final elements = _readElements(bytes, stopAtPixelData: false);
    final rows =
        _getInt(bytes, elements, 0x0028, 0x0010) ??
        (throw const FormatException('нет Rows'));
    final columns =
        _getInt(bytes, elements, 0x0028, 0x0011) ??
        (throw const FormatException('нет Columns'));
    final bitsAllocated = _getInt(bytes, elements, 0x0028, 0x0100) ?? 16;
    final bitsStored =
        _getInt(bytes, elements, 0x0028, 0x0101) ?? bitsAllocated;
    final pixelRepresentation = _getInt(bytes, elements, 0x0028, 0x0103) ?? 0;
    final photometric =
        _getString(bytes, elements, 0x0028, 0x0004) ?? 'MONOCHROME2';
    final slope = _getDouble(bytes, elements, 0x0028, 0x1053) ?? 1;
    final intercept = _getDouble(bytes, elements, 0x0028, 0x1052) ?? 0;
    final pixelData =
        elements[_tag(0x7FE0, 0x0010)] ??
        (throw const FormatException('нет PixelData'));
    if (bitsAllocated != 8 && bitsAllocated != 16) {
      throw UnsupportedError('BitsAllocated=$bitsAllocated');
    }

    final pixels = Int32List(rows * columns);
    var min = 1 << 30;
    var max = -(1 << 30);
    final bd = ByteData.sublistView(bytes);
    for (var i = 0; i < pixels.length; i++) {
      final offset = pixelData.valueOffset + (bitsAllocated == 16 ? i * 2 : i);
      var raw = bitsAllocated == 8
          ? (pixelRepresentation == 1
                ? bd.getInt8(offset)
                : bd.getUint8(offset))
          : (pixelRepresentation == 1
                ? bd.getInt16(offset, pixelData.endian)
                : bd.getUint16(offset, pixelData.endian));
      if (pixelRepresentation == 1 && bitsAllocated == 16 && bitsStored < 16) {
        final shift = 16 - bitsStored;
        raw = (raw << shift).toSigned(16) >> shift;
      }
      final value = (raw * slope + intercept).round();
      pixels[i] = value;
      min = math.min(min, value);
      max = math.max(max, value);
    }

    final wc = _getDouble(bytes, elements, 0x0028, 0x1050) ?? (min + max) / 2.0;
    final ww =
        _getDouble(bytes, elements, 0x0028, 0x1051) ??
        math.max(1, max - min).toDouble();
    final pixelSpacingRaw = _getString(bytes, elements, 0x0028, 0x0030);
    final spacingParts =
        pixelSpacingRaw
            ?.split('\\')
            .map(double.tryParse)
            .whereType<double>()
            .toList() ??
        const <double>[];
    final calculatedFov = spacingParts.length >= 2
        ? '${(columns * spacingParts[1] / 10).toStringAsFixed(1)} × ${(rows * spacingParts[0] / 10).toStringAsFixed(1)} cm'
        : null;
    final overlayTags = <String, String>{};
    void addTag(String name, int group, int element) {
      final value = _getString(bytes, elements, group, element);
      if (value != null && value.isNotEmpty) {
        overlayTags[name] = value.replaceAll('\\', '/');
      }
    }

    addTag('Manufacturer', 0x0008, 0x0070);
    addTag('InstitutionName', 0x0008, 0x0080);
    addTag('StationName', 0x0008, 0x1010);
    addTag('ManufacturerModelName', 0x0008, 0x1090);
    addTag('AccessionNumber', 0x0008, 0x0050);
    addTag('PatientBirthDate', 0x0010, 0x0030);
    addTag('PatientSex', 0x0010, 0x0040);
    addTag('PatientAge', 0x0010, 0x1010);
    addTag('StudyID', 0x0020, 0x0010);
    addTag('NumberOfStudyRelatedSeries', 0x0020, 0x1206);
    addTag('ImagesInAcquisition', 0x0020, 0x1002);
    addTag('ImageOrientationPatient', 0x0020, 0x0037);
    addTag('ScanningSequence', 0x0018, 0x0020);
    addTag('SequenceVariant', 0x0018, 0x0021);
    addTag('ScanOptions', 0x0018, 0x0022);
    addTag('MRAcquisitionType', 0x0018, 0x0023);
    addTag('SequenceName', 0x0018, 0x0024);
    addTag('MagneticFieldStrength', 0x0018, 0x0087);
    addTag('EchoTrainLength', 0x0018, 0x0091);
    addTag('PixelBandwidth', 0x0018, 0x0095);
    addTag('SoftwareVersions', 0x0018, 0x1020);
    addTag('ProtocolName', 0x0018, 0x1030);
    addTag('ReceiveCoilName', 0x0018, 0x1250);
    addTag('PatientPosition', 0x0018, 0x5100);
    addTag('NumberOfAverages', 0x0018, 0x0083);
    addTag('SpacingBetweenSlices', 0x0018, 0x0088);
    addTag('FlipAngle', 0x0018, 0x1314);
    addTag('SliceLocation', 0x0020, 0x1041);
    final acquisitionMatrix = _readUnsignedShorts(
      bytes,
      elements,
      0x0018,
      0x1310,
    );
    if (acquisitionMatrix.isNotEmpty) {
      final nonZero = acquisitionMatrix.where((value) => value > 0).toList();
      if (nonZero.length >= 2) {
        overlayTags['AcquisitionMatrix'] = '${nonZero[0]}/${nonZero[1]}';
      }
    }
    final metadata = [
      'Файл: ${path.split(Platform.pathSeparator).last}',
      'Пациент: ${Transliteration.toRussianName(_getString(bytes, elements, 0x0010, 0x0010))}',
      'ID: ${_getString(bytes, elements, 0x0010, 0x0020) ?? '—'}',
      'Исследование: ${_getString(bytes, elements, 0x0008, 0x1030) ?? '—'}',
      'Серия: ${_getString(bytes, elements, 0x0008, 0x103E) ?? '—'}',
      'Modality: ${_getString(bytes, elements, 0x0008, 0x0060) ?? '—'}',
      'Instance: ${_getInt(bytes, elements, 0x0020, 0x0013) ?? '—'}',
      'Размер: $columns×$rows',
      'Диапазон: $min…$max',
      'Window: ${wc.round()} / ${ww.round()}',
      'Transfer Syntax: ${_getString(bytes, elements, 0x0002, 0x0010) ?? '—'}',
    ].join('\n');

    return DicomImageData(
      width: columns,
      height: rows,
      pixels: pixels,
      min: min,
      max: max,
      windowCenter: wc,
      windowWidth: math.max(1, ww),
      invert: photometric.toUpperCase().startsWith('MONOCHROME1'),
      metadataText: metadata,
      overlayTags: overlayTags,
      studyDate: _getString(bytes, elements, 0x0008, 0x0020),
      studyTime: _getString(bytes, elements, 0x0008, 0x0030),
      repetitionTime: _getString(bytes, elements, 0x0018, 0x0080),
      echoTime: _getString(bytes, elements, 0x0018, 0x0081),
      sliceThickness: _getString(bytes, elements, 0x0018, 0x0050),
      pixelSpacing: _getString(
        bytes,
        elements,
        0x0028,
        0x0030,
      )?.replaceAll('\\', ' × '),
      fieldOfView: _getString(bytes, elements, 0x0018, 0x1100) ?? calculatedFov,
    );
  }

  static bool _hasPreamble(Uint8List bytes) =>
      bytes.length > 132 &&
      String.fromCharCodes(bytes.sublist(128, 132)) == 'DICM';
  static int _tag(int group, int element) => (group << 16) | element;

  static Map<int, Element> _readElements(
    Uint8List bytes, {
    required bool stopAtPixelData,
  }) {
    final elements = <int, Element>{};
    final bd = ByteData.sublistView(bytes);
    var offset = 132;
    var datasetExplicit = true;
    var datasetEndian = Endian.little;
    var readingFileMeta = true;
    while (offset + 8 <= bytes.length) {
      var endian = readingFileMeta ? Endian.little : datasetEndian;
      var group = bd.getUint16(offset, endian);
      var element = bd.getUint16(offset + 2, endian);

      // File Meta Information (0002,xxxx) всегда Little Endian. Начиная с
      // первого dataset-тега применяем порядок байтов из Transfer Syntax.
      if (readingFileMeta && group != 0x0002) {
        readingFileMeta = false;
        endian = datasetEndian;
        group = bd.getUint16(offset, endian);
        element = bd.getUint16(offset + 2, endian);
      }

      final item = _readElement(
        bytes,
        offset,
        readingFileMeta || datasetExplicit,
        endian,
      );
      if (item == null) break;
      if (item.length == 0xFFFFFFFF) {
        final next = _skipUndefinedSequence(
          bytes,
          item.valueOffset,
          item.endian,
        );
        if (next == null) break;
        offset = next;
        continue;
      }
      if (item.valueOffset + item.length > bytes.length) break;
      elements[_tag(group, element)] = item;
      if (group == 0x0002 && element == 0x0010) {
        final transferSyntax = _getStringFromElement(bytes, item);
        datasetExplicit = transferSyntax != '1.2.840.10008.1.2';
        datasetEndian = transferSyntax == '1.2.840.10008.1.2.2'
            ? Endian.big
            : Endian.little;
      }
      if (group == 0x7FE0 && element == 0x0010) break;
      offset = item.valueOffset + item.length + (item.length % 2);
      if (stopAtPixelData && group == 0x7FE0 && element == 0x0010) break;
    }
    return elements;
  }

  static Element? _readElement(
    Uint8List bytes,
    int offset,
    bool explicitVr,
    Endian endian,
  ) {
    final bd = ByteData.sublistView(bytes);
    final group = bd.getUint16(offset, endian);
    final element = bd.getUint16(offset + 2, endian);
    if (!explicitVr) {
      return Element(
        group,
        element,
        'UN',
        offset + 8,
        bd.getUint32(offset + 4, endian),
        endian,
      );
    }
    final vr = String.fromCharCodes(bytes.sublist(offset + 4, offset + 6));
    if (_longVr.contains(vr)) {
      return Element(
        group,
        element,
        vr,
        offset + 12,
        bd.getUint32(offset + 8, endian),
        endian,
      );
    }
    return Element(
      group,
      element,
      vr,
      offset + 8,
      bd.getUint16(offset + 6, endian),
      endian,
    );
  }

  static int? _skipUndefinedSequence(
    Uint8List bytes,
    int offset,
    Endian endian,
  ) {
    final bd = ByteData.sublistView(bytes);
    while (offset + 8 <= bytes.length) {
      final group = bd.getUint16(offset, endian);
      final element = bd.getUint16(offset + 2, endian);
      final length = bd.getUint32(offset + 4, endian);
      if (group == 0xFFFE && element == 0xE0DD) return offset + 8;
      if (length == 0xFFFFFFFF) {
        final nested = _skipUndefinedSequence(bytes, offset + 8, endian);
        if (nested == null) return null;
        offset = nested;
      } else {
        offset += 8 + length + (length % 2);
      }
    }
    return null;
  }

  static String? _getString(
    Uint8List bytes,
    Map<int, Element> elements,
    int group,
    int element,
  ) {
    final item = elements[_tag(group, element)];
    return item == null ? null : _getStringFromElement(bytes, item);
  }

  static String? _getStringFromElement(Uint8List bytes, Element item) {
    final text = String.fromCharCodes(
      bytes.sublist(item.valueOffset, item.valueOffset + item.length),
    ).replaceAll('\u0000', '').trim().replaceAll('^', ' ');
    return text.isEmpty ? null : text;
  }

  static int? _getInt(
    Uint8List bytes,
    Map<int, Element> elements,
    int group,
    int element,
  ) {
    final item = elements[_tag(group, element)];
    if (item == null) return null;
    final bd = ByteData.sublistView(bytes);
    if ((item.vr == 'US' || item.vr == 'SS' || item.vr == 'UN') &&
        item.length >= 2) {
      return item.vr == 'SS'
          ? bd.getInt16(item.valueOffset, item.endian)
          : bd.getUint16(item.valueOffset, item.endian);
    }
    return int.tryParse(_getStringFromElement(bytes, item) ?? '');
  }

  static double? _getDouble(
    Uint8List bytes,
    Map<int, Element> elements,
    int group,
    int element,
  ) {
    final item = elements[_tag(group, element)];
    if (item == null) return null;
    return double.tryParse(
      (_getStringFromElement(bytes, item) ?? '').split('\\').first,
    );
  }

  static List<int> _readUnsignedShorts(
    Uint8List bytes,
    Map<int, Element> elements,
    int group,
    int element,
  ) {
    final item = elements[_tag(group, element)];
    if (item == null || item.length < 2) return const [];
    final bd = ByteData.sublistView(bytes);
    return List<int>.generate(
      item.length ~/ 2,
      (index) => bd.getUint16(item.valueOffset + index * 2, item.endian),
    );
  }
}

class Element {
  Element(
    this.group,
    this.elementId,
    this.vr,
    this.valueOffset,
    this.length,
    this.endian,
  );
  final int group;
  final int elementId;
  final String vr;
  final int valueOffset;
  final int length;
  final Endian endian;
}

class Transliteration {
  static const _rules = [
    ['Shch', 'Щ'],
    ['shch', 'щ'],
    ['Sch', 'Щ'],
    ['sch', 'щ'],
    ['Zh', 'Ж'],
    ['zh', 'ж'],
    ['Kh', 'Х'],
    ['kh', 'х'],
    ['Tz', 'Ц'],
    ['tz', 'ц'],
    ['Ch', 'Ч'],
    ['ch', 'ч'],
    ['Sh', 'Ш'],
    ['sh', 'ш'],
    ['Iy', 'Ы'],
    ['iy', 'ы'],
    ['Yu', 'Ю'],
    ['yu', 'ю'],
    ['Ya', 'Я'],
    ['ya', 'я'],
    ['Eh', 'Э'],
    ['eh', 'э'],
    ['A', 'А'],
    ['a', 'а'],
    ['B', 'Б'],
    ['b', 'б'],
    ['V', 'В'],
    ['v', 'в'],
    ['G', 'Г'],
    ['g', 'г'],
    ['D', 'Д'],
    ['d', 'д'],
    ['E', 'Е'],
    ['e', 'е'],
    ['Z', 'З'],
    ['z', 'з'],
    ['I', 'И'],
    ['i', 'и'],
    ['Y', 'Й'],
    ['y', 'й'],
    ['K', 'К'],
    ['k', 'к'],
    ['L', 'Л'],
    ['l', 'л'],
    ['M', 'М'],
    ['m', 'м'],
    ['N', 'Н'],
    ['n', 'н'],
    ['O', 'О'],
    ['o', 'о'],
    ['P', 'П'],
    ['p', 'п'],
    ['R', 'Р'],
    ['r', 'р'],
    ['S', 'С'],
    ['s', 'с'],
    ['T', 'Т'],
    ['t', 'т'],
    ['U', 'У'],
    ['u', 'у'],
    ['F', 'Ф'],
    ['f', 'ф'],
    ['H', 'Х'],
    ['h', 'х'],
    ["'", 'ь'],
  ];
  static String toRussianName(String? value) {
    if (value == null || value.trim().isEmpty) return '—';
    return value
        .replaceAll('^', ' ')
        .trim()
        .split(RegExp(r'\s+'))
        .map(_transliterateWord)
        .map(_fixCommonName)
        .map(_formatPart)
        .join(' ');
  }

  static String _transliterateWord(String word) {
    final out = StringBuffer();
    for (var i = 0; i < word.length;) {
      var matched = false;
      for (final rule in _rules) {
        final latin = rule[0];
        if (word.startsWith(latin, i)) {
          out.write(rule[1]);
          i += latin.length;
          matched = true;
          break;
        }
      }
      if (!matched) out.write(word[i++]);
    }
    return out.toString();
  }

  static String _fixCommonName(String word) => switch (word) {
    'Илйа' || 'Иля' || 'Илиа' => 'Илья',
    'Наталя' || 'Наталйа' || 'Наталиа' => 'Наталья',
    'Тишченко' || 'Тисченко' => 'Тищенко',
    _ => word,
  };
  static String _formatPart(String word) => word.isEmpty
      ? word
      : word[0].toUpperCase() + word.substring(1).toLowerCase();
}
