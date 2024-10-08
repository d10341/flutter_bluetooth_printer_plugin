part of flutter_bluetooth_printer;

class DiscoveryResult extends DiscoveryState {
  final List<BluetoothDevice> devices;
  DiscoveryResult({required this.devices});
}

enum PaperSize {
  // original is 384 => 48 * 8
  mm58(360, 58, 'Roll Paper 58mm'),
  mm80(576, 80, 'Roll Paper 80mm');

  final int width;
  final double paperWidthMM;
  final String name;
  const PaperSize(
    this.width,
    this.paperWidthMM,
    this.name,
  );
}

class FlutterBluetoothPrinter {
  static Stream<DiscoveryState> _discovery() async* {
    final result = <BluetoothDevice>[];
    await for (final state
        in FlutterBluetoothPrinterPlatform.instance.discovery) {
      if (state is BluetoothDevice) {
        result.add(state);
        yield DiscoveryResult(devices: result.toSet().toList());
      } else {
        result.clear();
        yield state;
      }
    }
  }

  static ValueNotifier<BluetoothConnectionState> get connectionStateNotifier =>
      FlutterBluetoothPrinterPlatform.instance.connectionStateNotifier;

  static Stream<DiscoveryState> get discovery => _discovery();

  static Future<bool> printBytes({
    required String address,
    required Uint8List data,

    /// if true, you should manually disconnect the printer after finished
    required bool keepConnected,
    int maxBufferSize = 512,
    int delayTime = 120,
    ProgressCallback? onProgress,
  }) {
    return FlutterBluetoothPrinterPlatform.instance.write(
      address: address,
      data: data,
      onProgress: onProgress,
      keepConnected: keepConnected,
      maxBufferSize: maxBufferSize,
      delayTime: delayTime,
    );
  }

  static double calculatePrintingDurationInMilliseconds(
    int heightInDots,
    double printSpeed,
    int dotsPerLine,
    double paperWidth,
    int dotsPerLineHeight,
  ) {
    // Calculate the number of lines
    double numberOfLines = heightInDots / dotsPerLineHeight;

    // Calculate lines per second
    double linesPerSecond = printSpeed / paperWidth;

    // Calculate the duration in seconds
    double durationSeconds = numberOfLines / linesPerSecond;

    // Convert the duration to milliseconds
    double durationMilliseconds = durationSeconds * 1000;

    return durationMilliseconds;
  }

  static Future<bool> printImageSingle({
    required String address,
    required Uint8List imageBytes,
    required int imageWidth,
    required int imageHeight,
    PaperSize paperSize = PaperSize.mm80,
    ProgressCallback? onProgress,
    int addFeeds = 0,
    bool useImageRaster = true,
    required bool keepConnected,
    int maxBufferSize = 512,
    int delayTime = 120,
  }) async {
    try {
      final generator = Generator();
      final reset = generator.reset();

      final imageData = await generator.encode(
        bytes: imageBytes,
        dotsPerLine: paperSize.width,
        useImageRaster: useImageRaster,
      );

      await _initialize(
        address: address,
      );

      // waiting for printer initialized and buffers cleared
      await Future.delayed(const Duration(milliseconds: 400));

      final additional = <int>[
        for (int i = 0; i < addFeeds; i++) ...Commands.lineFeed,
      ];

      final printResult = await printBytes(
        keepConnected: true,
        address: address,
        data: Uint8List.fromList([
          ...imageData,
          ...reset,
          ...additional,
        ]),
        onProgress: onProgress,
        maxBufferSize: maxBufferSize,
        delayTime: delayTime,
      );

      return printResult;
    } catch (e) {
      return false;
    } finally {
      if (!keepConnected) {
        await disconnect(address);
      }
    }
  }

  static Future getImage({
    required List<int> imageBytes,
    required int imageWidth,
    required int imageHeight,
    PaperSize paperSize = PaperSize.mm80,
  }) async {
    final bytes = await _optimizeImage(
      paperSize: paperSize,
      src: imageBytes,
      srcWidth: imageWidth,
      srcHeight: imageHeight,
    );

    final hasAccess = await Gal.hasAccess();

    if (hasAccess) {
      final hasAccessToAlbum = await Gal.hasAccess(toAlbum: true);
      if (hasAccessToAlbum) {
        try {
          await Gal.putImageBytes(Uint8List.fromList(bytes));
          return true;
        } catch (e) {
          print(e);
        }
      } else {
        await Gal.requestAccess(toAlbum: true);
      }
    } else {
      // Request access premission
      await Gal.requestAccess();
    }

// ... for saving to album
  }

  static Future<List<int>> _optimizeImage({
    required List<int> src,
    required PaperSize paperSize,
    required int srcWidth,
    required int srcHeight,
  }) async {
    final arg = <String, dynamic>{
      'src': src,
      'width': srcWidth,
      'height': srcHeight,
      'paperSize': paperSize,
    };

    if (kIsWeb) {
      return _blackwhiteInternal(arg);
    }

    return compute(_blackwhiteInternal, arg);
  }

  static Future<bool> _initialize({
    required String address,
  }) async {
    final isConnected = await connect(address);
    if (!isConnected) {
      return false;
    }

    final generator = Generator();
    final reset = generator.reset();
    return printBytes(
      address: address,
      data: Uint8List.fromList(reset),
      keepConnected: true,
    );
  }

  static Future<BluetoothDevice?> selectDevice(BuildContext context) async {
    final selected = await showModalBottomSheet(
      context: context,
      builder: (context) => const BluetoothDeviceSelector(),
    );
    if (selected is BluetoothDevice) {
      return selected;
    }
    return null;
  }

  static Future<bool> disconnect(String address) async {
    return FlutterBluetoothPrinterPlatform.instance.disconnect(address);
  }

  static Future<bool> connect(String address) async {
    return FlutterBluetoothPrinterPlatform.instance.connect(address);
  }

  static Future<BluetoothState> getState() async {
    return FlutterBluetoothPrinterPlatform.instance.checkState();
  }

  static Future<List<int>> _blackwhiteInternal(Map<String, dynamic> arg) async {
    final srcBytes = arg['src'] as List<int>;
    final paperSize = arg['paperSize'] as PaperSize;

    final bytes = Uint8List.fromList(srcBytes);
    img.Image src = img.decodePng(bytes)!;

    final w = src.width;
    final h = src.height;

    final res = img.Image(width: w, height: h);
    for (int y = 0; y < h; ++y) {
      for (int x = 0; x < w; ++x) {
        final pixel = src.getPixel(x, y);

        img.Color c;
        final l = pixel.luminance / 255;
        if (l > 0.8) {
          c = img.ColorUint8.rgb(255, 255, 255);
        } else {
          c = img.ColorUint8.rgb(0, 0, 0);
        }

        res.setPixel(x, y, c);
      }
    }

    src = res;
    final dotsPerLine = paperSize.width;
    src = img.copyResize(
      src,
      width: dotsPerLine,
      maintainAspect: true,
    );

    return img.encodeJpg(src);
  }
}
