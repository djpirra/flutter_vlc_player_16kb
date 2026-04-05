import 'package:flutter/material.dart';
import 'package:flutter_vlc_player_16kb/flutter_vlc_player.dart';

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
  late VlcPlayerController _videoPlayerController;

  @override
  void initState() {
    super.initState();
    _videoPlayerController = VlcPlayerController.network(
      'http://line.8kultradnscloud.ru/movie/rbEmkPVz4d/EvQs9JQ7ps/2016280.mkv',
      hwAcc: HwAcc.full,
      autoPlay: true,
      options: VlcPlayerOptions(
        subtitle: VlcSubtitleOptions([
          // The goal is to prove setSubtitleHeightScale works,
          // so we can initialize with a scale or call it later.
          // VlcSubtitleOptions.fontSize(16), 
        ]),
      ),
    );
    
    // Add a listener to set scale once playing
    _videoPlayerController.addOnInitListener(() async {
        // Wait a bit for the player to be ready and start playback
        await Future.delayed(const Duration(seconds: 5));
        print('Setting subtitle scale to 0.5 (Font 8)');
        await _videoPlayerController.setSubtitleHeightScale(0.5);
    });
  }

  @override
  Future<void> dispose() async {
    await _videoPlayerController.stopRendererScanning();
    await _videoPlayerController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('VLC Subtitle Scale Test'),
      ),
      body: Center(
        child: Column(
          children: [
            VlcPlayer(
              controller: _videoPlayerController,
              aspectRatio: 16 / 9,
              placeholder: const Center(child: CircularProgressIndicator()),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                ElevatedButton(
                  onPressed: () => _videoPlayerController.setSubtitleHeightScale(0.5),
                  child: const Text('Set Font 8 (Scale 0.5)'),
                ),
                const SizedBox(width: 20),
                ElevatedButton(
                  onPressed: () => _videoPlayerController.setSubtitleHeightScale(1.0),
                  child: const Text('Set Font 16 (Scale 1.0)'),
                ),
                const SizedBox(width: 20),
                ElevatedButton(
                  onPressed: () => _videoPlayerController.setSubtitleHeightScale(2.0),
                  child: const Text('Set Font 32 (Scale 2.0)'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
