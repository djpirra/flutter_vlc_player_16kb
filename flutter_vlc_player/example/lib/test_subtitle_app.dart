import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_vlc_player_16kb/flutter_vlc_player.dart';

/// Test app verifying subtitle font-size options work with MobileVLCKit 3.
///
/// Since MobileVLCKit 3.x does not expose `currentSubTitleFontScale`,
/// font size is applied via `--freetype-rel-fontsize=N` as a media option
/// at player creation time. This app demonstrates that approach.
///
/// The "Set Scale" buttons recreate the controller with different font sizes
/// to prove the option pipeline works end-to-end.
void main() {
  runApp(
    MaterialApp(
      home: TestSubtitleApp(),
    ),
  );
}

class TestSubtitleApp extends StatefulWidget {
  @override
  _TestSubtitleAppState createState() => _TestSubtitleAppState();
}

class _TestSubtitleAppState extends State<TestSubtitleApp> {
  static const _url =
      'http://line.8kultradnscloud.ru/movie/rbEmkPVz4d/EvQs9JQ7ps/2016280.mkv';

  late VlcPlayerController _controller;
  double _fontSize = 16;
  String _statusMessage = 'Initializing with font size 16 via --freetype-rel-fontsize…';

  @override
  void initState() {
    super.initState();
    _controller = _buildController(fontSize: _fontSize);
  }

  VlcPlayerController _buildController({required double fontSize}) {
    final ctrl = VlcPlayerController.network(
      _url,
      hwAcc: HwAcc.full,
      options: VlcPlayerOptions(
        // Font size is applied at media creation via the Freetype VLC flag.
        // This is the MobileVLCKit 3-compatible approach (no currentSubTitleFontScale).
        subtitle: VlcSubtitleOptions([
          VlcSubtitleOptions.relativeFontSize(fontSize.toInt()),
          VlcSubtitleOptions.boldStyle(true),
          VlcSubtitleOptions.color(VlcSubtitleColor.white),
          VlcSubtitleOptions.backgroundColor(VlcSubtitleColor.black),
          VlcSubtitleOptions.backgroundOpacity(180),
          VlcSubtitleOptions.outlineThickness(VlcSubtitleThickness.normal),
        ]),
      ),
    );

    ctrl.addOnInitListener(() async {
      if (kDebugMode) {
        debugPrint(
          '[TestSubtitleApp] Player initialized with --freetype-rel-fontsize=${fontSize.toInt()}',
        );
      }
      if (mounted) {
        setState(() {
          _statusMessage =
              'Player ready — font size ${fontSize.toInt()} via --freetype-rel-fontsize';
        });
      }
    });

    return ctrl;
  }

  Future<void> _applyFontSize(double newSize) async {
    if (mounted) {
      setState(() {
        _statusMessage = 'Restarting with font size ${newSize.toInt()}…';
      });
    }

    final old = _controller;
    await old.stopRendererScanning();
    await old.dispose();

    if (!mounted) return;
    setState(() {
      _fontSize = newSize;
      _controller = _buildController(fontSize: newSize);
      _statusMessage = 'Initialized with font size ${newSize.toInt()} (--freetype-rel-fontsize)';
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('VLC Font Size Test (MobileVLCKit 3)'),
      ),
      body: Column(
        children: [
          VlcPlayer(
            controller: _controller,
            aspectRatio: 16 / 9,
            placeholder: const Center(child: CircularProgressIndicator()),
          ),
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text(
              _statusMessage,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ),
          Wrap(
            spacing: 8,
            children: [
              _fontButton('Font 8', 8),
              _fontButton('Font 14', 14),
              _fontButton('Font 16 (default)', 16),
              _fontButton('Font 24', 24),
              _fontButton('Font 32', 32),
            ],
          ),
        ],
      ),
    );
  }

  Widget _fontButton(String label, double size) => ElevatedButton(
        onPressed: () => _applyFontSize(size),
        child: Text(label),
      );

  @override
  Future<void> dispose() async {
    await _controller.stopRendererScanning();
    await _controller.dispose();
    super.dispose();
  }
}
