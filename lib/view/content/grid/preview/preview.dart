import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_avif/flutter_avif.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:once_power/core/context_menu.dart';
import 'package:once_power/core/list.dart';
import 'package:once_power/enum/file.dart';
import 'package:once_power/model/file.dart';
import 'package:once_power/provider/list.dart';
import 'package:once_power/util/psd.dart';
import 'package:once_power/widget/common/click_icon.dart';

import 'avif.dart';
import 'image.dart';
import 'psd.dart';
import 'svg.dart';
import 'video.dart';

class PreviewView extends ConsumerStatefulWidget {
  const PreviewView(this.file, {super.key});

  final FileInfo file;

  @override
  ConsumerState<ConsumerStatefulWidget> createState() =>
      _PreviewImageViewState();
}

class _PreviewImageViewState extends ConsumerState<PreviewView> {
  /// 超大的图不预加载：解码后占的是 w*h*4 字节。
  /// 25MP ≈ 100MB，当前这张 + 预加载 3 张 ≈ 400MB，正好落在 main.dart 里
  /// 放宽后的 ImageCache（512MB）之内，不会互相挤掉
  static const int _maxPreloadBytes = 30 * 1024 * 1024;
  static const int _maxPreloadPixels = 25 * 1000 * 1000;

  /// 翻页后延迟一点再启动预加载，让当前这张先抢到解码线程
  static const Duration _preloadDelay = Duration(milliseconds: 80);

  FocusNode focusNode = FocusNode();
  int index = 0;
  List<FileInfo> previewList = [];
  Timer? _preloadTimer;

  /// 上一次是往后翻还是往前翻：决定预加载窗口往哪边多铺一张
  bool _forward = true;

  @override
  void initState() {
    super.initState();
    previewList.addAll(ref.read(sortListProvider));
    index = previewList.indexOf(widget.file);
    setState(() {});
    // 等首帧结束、当前图已经上屏之后再预加载，避免和当前图抢解码资源
    WidgetsBinding.instance.addPostFrameCallback((_) => _preloadNeighbors());
  }

  @override
  void dispose() {
    _preloadTimer?.cancel();
    focusNode.dispose();
    super.dispose();
  }

  /// 触发预加载。加了 80ms 防抖：连着翻页时不让预加载和当前这张抢解码线程；
  /// 一旦定时器已经触发，解码就在后台跑完，不会被下一次翻页打断
  void _preloadNeighbors() {
    _preloadTimer?.cancel();
    if (!mounted || previewList.length < 2) return;
    _preloadTimer = Timer(_preloadDelay, _runPreload);
  }

  /// 沿翻页方向铺 2 张、反方向铺 1 张：
  /// 一直往前翻时，下一张在两步之前就开始解码了，等于给解码多一倍的时间预算
  void _runPreload() {
    if (!mounted || previewList.length < 2) return;
    final int len = previewList.length;
    final List<int> steps = _forward
        ? <int>[index + 1, index + 2, index - 1]
        : <int>[index - 1, index - 2, index + 1];
    final Set<int> targets = <int>{};
    for (final int step in steps) {
      final int i = ((step % len) + len) % len;
      if (i != index) targets.add(i);
    }
    for (final int i in targets) {
      _preloadAt(i);
    }
  }

  /// 按类型把图片提前解码进 ImageCache。
  /// 视频 / svg 跳过：视频要的是播放器实例不是位图，svg 是矢量、按需光栅化
  Future<void> _preloadAt(int i) async {
    if (!mounted || i < 0 || i >= previewList.length || i == index) return;
    final FileInfo file = previewList[i];
    if (file.type.isVideo) return;
    final String ext = file.extension.toLowerCase();
    if (ext == 'svg' || ext == 'svgz') return;
    if (!file.type.isImage && ext != 'avif' && ext != 'psd' && ext != 'psb') {
      return;
    }
    if (file.size > _maxPreloadBytes) return;
    final Resolution? resolution = file.resolution;
    if (resolution != null &&
        resolution.width * resolution.height > _maxPreloadPixels) {
      return;
    }
    try {
      if (ext == 'avif') {
        await precacheImage(FileAvifImage(File(file.path)), context);
      } else if (ext == 'psd' || ext == 'psb') {
        // psd 先热一下已有的缩略图，再去跑真正的解码：
        // PsdUtils 内部有静态缓存，命中后切过去就是秒开
        final Uint8List? thumb = file.thumbnail;
        if (thumb != null) {
          await precacheImage(MemoryImage(thumb), context);
        }
        await PsdUtils.loadPsdImage(file.path);
      } else {
        await precacheImage(FileImage(File(file.path)), context);
      }
    } catch (e) {
      // 预加载失败无所谓，切过去时组件自己会走 errorBuilder
      debugPrint('[PreviewView] 预加载失败: ${file.path} $e');
    }
  }

  void previous() {
    index = index == 0 ? previewList.length - 1 : index - 1;
    _forward = false;
    setState(() {});
    _preloadNeighbors();
  }

  void next() {
    index = index == previewList.length - 1 ? 0 : index + 1;
    _forward = true;
    setState(() {});
    _preloadNeighbors();
  }

  void delete() {
    // String id = previewList[index].id;
    int currentIndex = index;
    removeOne(ref, previewList[index]);
    previewList.remove(previewList[currentIndex]);
    if (previewList.isEmpty) return Navigator.pop(context);
    if (currentIndex == previewList.length) index = 0;
    setState(() {});
    _preloadNeighbors();
  }

  void onKeyEvent(KeyEvent e) {
    if (e is KeyUpEvent) {
      if (e.physicalKey == PhysicalKeyboardKey.arrowLeft ||
          e.physicalKey == PhysicalKeyboardKey.arrowUp) {
        previous();
      } else if (e.physicalKey == PhysicalKeyboardKey.arrowRight ||
          e.physicalKey == PhysicalKeyboardKey.arrowDown) {
        next();
      } else if (e.physicalKey == PhysicalKeyboardKey.delete) {
        delete();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black.withValues(alpha: .5),
      child: InkWell(
        mouseCursor: SystemMouseCursors.click,
        splashColor: Colors.transparent,
        onTap: () => Navigator.pop(context),
        onSecondaryTapDown: (details) => showRightMenu(
          context,
          ref,
          details.globalPosition,
          previewList[index],
          true,
        ),
        child: KeyboardListener(
          focusNode: focusNode,
          autofocus: true,
          onKeyEvent: onKeyEvent,
          child: Stack(
            fit: StackFit.expand,
            children: [
              Builder(
                builder: (BuildContext context) {
                  if (previewList[index].type.isVideo) {
                    return PreviewVideo(
                      file: previewList[index].path,
                      key: ValueKey(previewList[index].id),
                    );
                  }

                  if (previewList[index].extension == 'avif') {
                    return PreviewAvif(
                      id: previewList[index].id,
                      file: previewList[index].path,
                    );
                  }

                  if (previewList[index].extension == 'psd') {
                    return PreviewPsd(
                      id: previewList[index].id,
                      file: previewList[index],
                      data: previewList[index].thumbnail,
                    );
                  }

                  if (previewList[index].extension == 'svg') {
                    return PreviewSvg(
                      id: previewList[index].id,
                      file: previewList[index].path,
                    );
                  }

                  return PreviewImage(
                    id: previewList[index].id,
                    file: previewList[index].path,
                  );
                },
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  ClickIcon(
                    icon: Icons.keyboard_arrow_left_rounded,
                    onPressed: previous,
                    color: Colors.white,
                    size: 48,
                    iconSize: 40,
                  ),
                  ClickIcon(
                    icon: Icons.keyboard_arrow_right_rounded,
                    onPressed: next,
                    color: Colors.white,
                    size: 48,
                    iconSize: 40,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
