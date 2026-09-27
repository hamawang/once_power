import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:once_power/const/num.dart';
import 'package:once_power/util/format.dart';
import 'package:video_player/video_player.dart';

import '../error.dart';
import '../loading.dart';
import 'video_button.dart';
import 'video_progress.dart';

class PreviewVideo extends StatefulWidget {
  const PreviewVideo({super.key, required this.file});

  final String file;

  @override
  State<PreviewVideo> createState() => _PreviewVideoState();
}

class _PreviewVideoState extends State<PreviewVideo> {
  late VideoPlayerController _controller;
  Future<void>? _initializeFuture;
  bool _disposed = false;
  Duration totalDuration = Duration.zero;
  Duration currentPosition = Duration.zero;
  String timeLine = '';
  bool isError = false;

  @override
  void initState() {
    super.initState();
    // fvp 0.38.1 的一个已知问题：MdkVideoPlayer.dispose() 只 close 了事件流，
    // 没有取消 onStateChanged / onEvent 的原生订阅，播放器释放后原生仍会推状态变更过来，
    // 往已关闭的 StreamController 里 add 就抛 "Bad state: Cannot add event after closing"。
    // 把播放器的创建放进独立 zone，这类事件回调就会落进下面的 guard，而不是变成 unhandled 异常。
    runZonedGuarded(
      () {
        _controller = VideoPlayerController.file(File(widget.file));
        _controller.addListener(_videoListener);
        // 保存初始化 future：dispose 时要用它做「等初始化落地再释放」，
        // 否则原生播放器边创建边销毁会直接把进程带崩（不是 Dart 异常，抓不到）
        _initializeFuture = _controller
            .initialize()
            .then<void>((_) {
              if (_disposed) return;
              _controller.play().catchError((Object _) {});
              totalDuration = _controller.value.duration;
              if (mounted) setState(() {});
            })
            .catchError((Object _) {
              if (_disposed || !mounted) return;
              setState(() => isError = true);
            });
      },
      (Object error, StackTrace stack) {
        debugPrint('[PreviewVideo] 忽略播放器销毁后的原生事件: $error');
      },
    );
  }

  void _videoListener() {
    if (_disposed || !mounted) return;
    if (_controller.value.isCompleted) {
      _controller.pause().catchError((Object _) {});
    }
    currentPosition = _controller.value.position;
    timeLine = formatVideoTime(totalDuration, currentPosition);
    setState(() {});
  }

  @override
  void dispose() {
    _disposed = true;
    _controller.removeListener(_videoListener);
    // fvp/video_player 在 Windows 上是原生解码器：initialize() 还没返回就 dispose()，
    // 原生侧会拿到一个尚未就绪的实例去释放 —— 进程级闪退，Dart 层 catch 不到。
    // 所以这里等初始化（或失败）结束后再释放，并用超时兜底防止初始化永不返回导致泄漏。
    (_initializeFuture ?? Future<void>.value())
        .timeout(const Duration(seconds: 5), onTimeout: () {})
        .whenComplete(() {
          // 再错开几十毫秒：删除/切换预览项时，旧播放器销毁和新播放器创建往往落在同一帧，
          // 原生层并发「创建 + 销毁」是最容易炸的组合，延后一点可显著降低概率。
          Future<void>.delayed(const Duration(milliseconds: 80), () {
            try {
              _controller.pause().catchError((Object _) {});
            } catch (_) {}
            try {
              _controller.dispose();
            } catch (_) {}
          });
        });
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (isError) return ErrorImage(file: widget.file, isPreview: true);
    if (_controller.value.isInitialized) {
      if (_controller.value.hasError) {
        return Center(child: ErrorImage(isPreview: true, file: widget.file));
      }
      return Column(
        children: [
          Expanded(
            child: Center(
              child: FittedBox(
                fit: BoxFit.contain,
                child: SizedBox(
                  width: _controller.value.size.width,
                  height: _controller.value.size.height,
                  child: VideoPlayer(_controller),
                ),
              ),
            ),
          ),
          Row(
            children: [
              PlayButton(controller: _controller),
              Expanded(
                child: CustomVideoProgressIndicator(
                  _controller,
                  allowScrubbing: true,
                  padding: EdgeInsets.zero,
                  colors: VideoProgressColors(
                    playedColor: Theme.of(context).colorScheme.primary,
                    backgroundColor: Colors.white,
                  ),
                ),
              ),
              SizedBox(width: AppNum.spaceLarge),
              Text(timeLine, style: TextStyle(color: Colors.white)),
              SizedBox(width: AppNum.spaceLarge),
            ],
          ),
        ],
      );
    }
    return Center(child: LoadingImage(isPreview: true));
  }
}
